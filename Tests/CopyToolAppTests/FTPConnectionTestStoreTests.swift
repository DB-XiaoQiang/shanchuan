import XCTest
import CopyToolCore
@testable import CopyToolApp

final class FTPConnectionTestStoreTests: XCTestCase {
    @MainActor
    func testUsesCurrentDraftIncludingItsRawPortAndCredentials() async throws {
        let worker = StubFTPConnectionTest()
        let store = FTPConnectionTestStore(makeTest: { worker })
        var input = syntheticInput()
        input.host = "current-draft.invalid"
        input.portText = "2121"
        input.username = "draft-user"
        input.password = "draft-secret"
        input.directory = "/draft/destination"

        store.test(input: input)
        XCTAssertEqual(store.state, .testing)
        try await waitUntil { worker.startedCount == 1 }
        XCTAssertEqual(worker.settings, [FTPSettings(host: input.host, port: 2121,
                                                   username: input.username, password: input.password,
                                                   directory: input.directory)])
        worker.finish()
        try await waitUntil { store.state == .success }
        XCTAssertEqual(store.state.text, "连接成功，已登录且目标目录可访问。")
    }

    @MainActor
    func testInvalidRawPortsDoNotStartANetworkWorker() async throws {
        let factory = StubFTPConnectionFactory()
        let store = FTPConnectionTestStore(makeTest: { factory.make() })
        for port in ["", "0", "65536", "21x", "+21", "-21", " 21", "21 ", "２１", "2\n1"] {
            var input = syntheticInput()
            input.portText = port
            store.test(input: input)
            guard case .failed(let message) = store.state else {
                XCTFail("非法草稿端口不得使用已保存端口继续连接：\(port)")
                continue
            }
            XCTAssertTrue(message.contains("端口"))
        }
        XCTAssertEqual(factory.creationCount, 0)
    }

    @MainActor
    func testInvalidHostWhitespaceAndRelativeDirectoryDoNotStartAWorker() async throws {
        let factory = StubFTPConnectionFactory()
        let store = FTPConnectionTestStore(makeTest: { factory.make() })
        for host in ["", " host.invalid", "host.invalid ", "host name", "host\tname", "host\nname"] {
            var input = syntheticInput()
            input.host = host
            store.test(input: input)
            guard case .failed = store.state else { XCTFail("非法主机不得发起测试"); continue }
        }
        for directory in ["", "relative/path"] {
            var input = syntheticInput()
            input.directory = directory
            store.test(input: input)
            guard case .failed = store.state else { XCTFail("相对目录不得被隐式转换后发起测试"); continue }
        }
        XCTAssertEqual(factory.creationCount, 0)
    }

    @MainActor
    func testShowsConcreteCoreFailureAndRecoversOnRetry() async throws {
        let first = StubFTPConnectionTest()
        let second = StubFTPConnectionTest()
        let factory = StubFTPConnectionFactory(workers: [first, second])
        let store = FTPConnectionTestStore(makeTest: { factory.make() })
        let input = syntheticInput()

        store.test(input: input)
        try await waitUntil { first.startedCount == 1 }
        first.finish(error: FTPConnectionTestError.authenticationFailed)
        try await waitUntil { store.state == .failed("FTP 登录失败，请检查用户名和密码。") }
        store.test(input: input)
        try await waitUntil { second.startedCount == 1 }
        second.finish()
        try await waitUntil { store.state == .success }
        XCTAssertEqual(factory.creationCount, 2)
    }

    @MainActor
    func testDuplicateClicksDoNotCreateConcurrentTests() async throws {
        let worker = StubFTPConnectionTest()
        let factory = StubFTPConnectionFactory(workers: [worker])
        let store = FTPConnectionTestStore(makeTest: { factory.make() })
        let input = syntheticInput()
        store.test(input: input)
        store.test(input: input)
        store.test(input: input)
        try await waitUntil { worker.startedCount == 1 }
        XCTAssertEqual(factory.creationCount, 1)
        worker.finish()
        try await waitUntil { store.state == .success }
    }

    @MainActor
    func testUnchangedInputKeepsResultButEditingClearsIt() async throws {
        let worker = StubFTPConnectionTest()
        let store = FTPConnectionTestStore(makeTest: { worker })
        var input = syntheticInput()
        store.test(input: input)
        try await waitUntil { worker.startedCount == 1 }
        worker.finish()
        try await waitUntil { store.state == .success }

        store.inputChanged(input)
        XCTAssertEqual(store.state, .success)
        input.directory = "/different"
        store.inputChanged(input)
        XCTAssertEqual(store.state, .idle)
        XCTAssertEqual(worker.cancelCount, 0)
    }

    @MainActor
    func testEditingCancelsOldWorkerAndOldResultCannotReplaceNewResult() async throws {
        let old = StubFTPConnectionTest()
        let current = StubFTPConnectionTest()
        let factory = StubFTPConnectionFactory(workers: [old, current])
        let store = FTPConnectionTestStore(makeTest: { factory.make() })
        var input = syntheticInput()
        store.test(input: input)
        try await waitUntil { old.startedCount == 1 }
        input.host = "new-draft.invalid"
        store.inputChanged(input)
        XCTAssertEqual(old.cancelCount, 1)
        XCTAssertEqual(store.state, .idle)

        store.test(input: input)
        try await waitUntil { current.startedCount == 1 }
        current.finish(error: FTPConnectionTestError.directoryUnavailable)
        try await waitUntil { store.state == .failed("FTP 已连接，但无法进入目标目录，请检查目录路径和访问权限。") }
        // 模拟取消未及时退出的旧测试晚于新测试返回成功。
        old.finish()
        try await waitUntil { old.finishedCount == 1 }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(store.state, .failed("FTP 已连接，但无法进入目标目录，请检查目录路径和访问权限。"))
        XCTAssertEqual(current.cancelCount, 0)
    }

    @MainActor
    func testClosingCancelsOnlyActiveTestAndIgnoresItsLateResult() async throws {
        let worker = StubFTPConnectionTest()
        let store = FTPConnectionTestStore(makeTest: { worker })
        store.test(input: syntheticInput())
        try await waitUntil { worker.startedCount == 1 }
        store.cancel()
        XCTAssertEqual(worker.cancelCount, 1)
        XCTAssertEqual(store.state, .idle)
        store.cancel()
        XCTAssertEqual(worker.cancelCount, 1)
        worker.finish(error: FTPConnectionTestError.timedOut)
        try await waitUntil { worker.finishedCount == 1 }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(store.state, .idle)
    }

    @MainActor
    func testCoreCancellationReturnsToIdleWithoutShowingFailure() async throws {
        let worker = StubFTPConnectionTest()
        let store = FTPConnectionTestStore(makeTest: { worker })
        store.test(input: syntheticInput())
        try await waitUntil { worker.startedCount == 1 }
        worker.finish(error: FTPConnectionTestError.cancelled)
        try await waitUntil { store.state == .idle }
    }

    @MainActor
    func testUnknownErrorsNeverDisplayTheirPotentiallySensitiveDescription() async throws {
        let worker = StubFTPConnectionTest()
        let store = FTPConnectionTestStore(makeTest: { worker })
        store.test(input: syntheticInput())
        try await waitUntil { worker.startedCount == 1 }
        worker.finish(error: SensitiveSyntheticError())
        try await waitUntil { store.state == .failed("FTP 连接测试失败，请检查服务状态和配置。") }
        XCTAssertFalse(store.state.text.contains("synthetic-password"))
        XCTAssertFalse(store.state.text.contains("server-echo"))
    }

    @MainActor
    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !predicate(), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(predicate(), "FTP 测试状态未在限定时间内更新")
    }
}

private func syntheticInput() -> FTPConnectionTestInput {
    FTPConnectionTestInput(host: "synthetic.invalid", portText: "21", username: "synthetic-user",
                           password: "synthetic-password", directory: "/synthetic")
}

private struct SensitiveSyntheticError: LocalizedError {
    var errorDescription: String? { "server-echo synthetic-user:synthetic-password" }
}

private final class StubFTPConnectionTest: FTPConnectionTesting, @unchecked Sendable {
    private let lock = NSLock()
    private let completion = DispatchSemaphore(value: 0)
    private var receivedSettings: [FTPSettings] = []
    private var cancellations = 0
    private var finishes = 0
    private var failure: Error?

    var startedCount: Int { lock.lock(); defer { lock.unlock() }; return receivedSettings.count }
    var cancelCount: Int { lock.lock(); defer { lock.unlock() }; return cancellations }
    var finishedCount: Int { lock.lock(); defer { lock.unlock() }; return finishes }
    var settings: [FTPSettings] { lock.lock(); defer { lock.unlock() }; return receivedSettings }

    func test(settings: FTPSettings) throws {
        lock.lock(); receivedSettings.append(settings); lock.unlock()
        guard completion.wait(timeout: .now() + 3) == .success else { throw FTPConnectionTestError.timedOut }
        lock.lock(); let error = failure; finishes += 1; lock.unlock()
        if let error { throw error }
    }

    func cancel() { lock.lock(); cancellations += 1; lock.unlock() }

    func finish(error: Error? = nil) {
        lock.lock(); failure = error; lock.unlock()
        completion.signal()
    }
}

private final class StubFTPConnectionFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var workers: [StubFTPConnectionTest]
    private var creations = 0
    init(workers: [StubFTPConnectionTest] = []) { self.workers = workers }
    var creationCount: Int { lock.lock(); defer { lock.unlock() }; return creations }

    func make() -> any FTPConnectionTesting {
        lock.lock(); defer { lock.unlock() }
        creations += 1
        return workers.isEmpty ? StubFTPConnectionTest() : workers.removeFirst()
    }
}
