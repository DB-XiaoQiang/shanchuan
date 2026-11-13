import XCTest
import CryptoKit
import CopyToolCore
@testable import CopyToolApp

private actor UpdateFixtureNetwork {
    let responses: [String: Data]
    var requests: [String] = []
    init(responses: [String: Data]) { self.responses = responses }
    func load(_ url: URL, maximum: Int64) throws -> Data {
        requests.append(url.absoluteString)
        guard let response = responses[url.lastPathComponent], response.count <= maximum else {
            throw UpdateFailure.invalid("模拟响应不可用")
        }
        return response
    }
    func count() -> Int { requests.count }
    func urls() -> [String] { requests }
}

private actor UpdateFixtureHTTPFailureNetwork {
    let status: Int
    private var requestCount = 0
    private var blocked: Bool
    private var pending: [CheckedContinuation<Void, Never>] = []
    init(status: Int, blocked: Bool = false) { self.status = status; self.blocked = blocked }
    func load(_ url: URL, maximum: Int64) async throws -> Data {
        requestCount += 1
        if blocked { await withCheckedContinuation { pending.append($0) } }
        throw UpdateHTTPFailure.status(status)
    }
    func count() -> Int { requestCount }
    func release() {
        blocked = false
        let requests = pending; pending = []
        for request in requests { request.resume() }
    }
}

private actor UpdateFixtureRelay {
    var names: [String] = []
    var destinations: [String] = []
    var failNext = false
    func failOnce() { failNext = true }
    func upload(_ file: URL, name: String, settings: FTPSettings) throws {
        _ = try Data(contentsOf: file)
        if failNext { failNext = false; throw UpdateFailure.invalid("合成中断") }
        names.append(name); destinations.append(settings.directory)
    }
    func snapshot() -> ([String], [String]) { (names, destinations) }
}

final class UpdateCoordinatorTests: XCTestCase {
    private struct Fixture {
        let key: String
        let responses: [String: Data]
    }
    private func fixture(version: String = "0.4.0", prerelease: Bool = false, corruptPackage: Bool = false,
                         manifestChannel: String = "stable", tagPrefix: String = "v", macOnly: Bool = false,
                         draft: Bool = false) throws -> Fixture {
        let signingKey = P256.Signing.PrivateKey()
        let package = Data("windows package".utf8), zip = Data("macos synthetic zip".utf8), appcast = Data("<rss/>".utf8)
        let fullName = "Shanchuan-\(version)-win-x64-full.nupkg"
        let feed = try JSONSerialization.data(withJSONObject: ["Assets": [["PackageId": "Shanchuan", "FileName": fullName,
            "Version": version, "Type": "Full", "Size": package.count, "SHA256": UpdateVerifier.sha256(package)]]])
        func asset(_ platform: String, _ arch: String, _ kind: String, _ name: String, _ bytes: Data) -> [String: Any] {
            ["platform": platform, "arch": arch, "kind": kind, "name": name, "size": bytes.count, "sha256": UpdateVerifier.sha256(bytes)]
        }
        let macAssets = [asset("macos", "arm64", "sparkle-zip", "Shanchuan-macos-arm64.zip", zip),
                         asset("macos", "arm64", "appcast", "appcast.xml", appcast)]
        let assets = macOnly ? macAssets : [asset("windows", "x64", "velopack-full", fullName, package),
                                          asset("windows", "x64", "velopack-feed", "releases.win-x64.json", feed)] + macAssets
        let manifest = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "product": "Shanchuan", "channel": manifestChannel, "version": version, "releaseNotes": "合成更新说明",
            "assets": assets
        ], options: [.sortedKeys])
        let metadata = try JSONSerialization.data(withJSONObject: ["tag_name": tagPrefix + version, "draft": draft, "prerelease": prerelease])
        return Fixture(key: signingKey.publicKey.pemRepresentation, responses: [
            "latest": metadata, "update-test-v0.1.4": metadata,
            "update-manifest.json": manifest, "update-manifest.sig": try signingKey.signature(for: manifest).derRepresentation,
            fullName: corruptPackage ? Data("CORRUPTED".utf8) : package,
            "releases.win-x64.json": feed, "Shanchuan-macos-arm64.zip": macOnly && corruptPackage ? Data("CORRUPTED".utf8) : zip, "appcast.xml": appcast
        ])
    }
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }
    @MainActor private func waitForRelay(_ coordinator: UpdateCoordinator) async throws {
        for _ in 0..<100 {
            if !coordinator.isRelaying { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("合成更新转发未结束")
    }
    @MainActor func testVerifiedAutomaticDownloadDoesNotRequestInstallationAndRestoresAcrossRestart() async throws {
        let sample = try fixture(), root = try temporaryRoot(), network = UpdateFixtureNetwork(responses: sample.responses)
        var installs = 0
        var coordinator: UpdateCoordinator? = UpdateCoordinator(root: root, currentVersion: "0.3.0", publicKey: sample.key,
            dataLoader: { try await network.load($0, maximum: $1) })
        coordinator!.install = { _ in installs += 1; return true }
        await coordinator!.checkNow()
        XCTAssertEqual(coordinator!.candidateVersion, "0.4.0"); XCTAssertTrue(coordinator!.canInstall)
        XCTAssertEqual(installs, 0); XCTAssertFalse(coordinator!.waitingForInstallation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("history.json").path))
        coordinator = nil
        let count = await network.count()
        let restored = UpdateCoordinator(root: root, currentVersion: "0.3.0", publicKey: sample.key,
            dataLoader: { try await network.load($0, maximum: $1) })
        restored.install = { _ in installs += 1; return true }; restored.start()
        XCTAssertEqual(restored.candidateVersion, "0.4.0")
        try await Task.sleep(nanoseconds: 50_000_000)
        let restoredCount = await network.count()
        XCTAssertEqual(restoredCount, count, "同一01:00窗口重启不应再次查询GitHub")
        XCTAssertEqual(installs, 0)
    }
    @MainActor func testMacAlreadyLatestStillRelaysWindowsWithSignatureLastAndDeduplicates() async throws {
        let sample = try fixture(), network = UpdateFixtureNetwork(responses: sample.responses), relay = UpdateFixtureRelay()
        let coordinator = UpdateCoordinator(root: try temporaryRoot(), currentVersion: "0.4.0", publicKey: sample.key,
            dataLoader: { try await network.load($0, maximum: $1) }, upload: { try await relay.upload($0, name: $1, settings: $2) })
        coordinator.ftpSettings = { FTPSettings(host: "127.0.0.1", username: "synthetic", password: "", directory: "/share") }
        await coordinator.checkNow(); try await waitForRelay(coordinator)
        XCTAssertNil(coordinator.candidateVersion)
        var (names, paths) = await relay.snapshot()
        XCTAssertEqual(names, ["Shanchuan-0.4.0-win-x64-full.nupkg", "releases.win-x64.json", "update-manifest.json", "update-manifest.sig"])
        XCTAssertEqual(Set(paths).count, 1)
        let batch = try XCTUnwrap(paths.first?.split(separator: "/").last)
        XCTAssertEqual(batch.count, 32)
        XCTAssertTrue(batch.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) })
        XCTAssertTrue(try XCTUnwrap(paths.first).hasPrefix("/share/shanchuan_updates/stable/win-x64/0.4.0/"))
        await coordinator.checkNow(); try await waitForRelay(coordinator)
        (names, paths) = await relay.snapshot(); XCTAssertEqual(names.count, 4)
        XCTAssertTrue(coordinator.relayStatus.contains("不代表内网已安装"))
    }
    @MainActor func testInterruptedRelayRemainsRetryableAndNeverCommitsEarly() async throws {
        let sample = try fixture(), network = UpdateFixtureNetwork(responses: sample.responses), relay = UpdateFixtureRelay()
        await relay.failOnce()
        let coordinator = UpdateCoordinator(root: try temporaryRoot(), currentVersion: "0.3.0", publicKey: sample.key,
            dataLoader: { try await network.load($0, maximum: $1) }, upload: { try await relay.upload($0, name: $1, settings: $2) })
        coordinator.ftpSettings = { FTPSettings(host: "127.0.0.1", username: "synthetic", directory: "/") }
        await coordinator.checkNow(); try await waitForRelay(coordinator)
        var snapshot = await relay.snapshot(); XCTAssertTrue(snapshot.0.isEmpty)
        XCTAssertTrue(coordinator.relayStatus.contains("失败"))
        coordinator.retry()
        try await Task.sleep(nanoseconds: 30_000_000); try await waitForRelay(coordinator)
        snapshot = await relay.snapshot()
        XCTAssertEqual(snapshot.0.last, "update-manifest.sig")
        XCTAssertEqual(snapshot.0.count, 4)
    }
    @MainActor func testPrereleaseAndTamperedPackageNeverBecomeInstallableOrRelayed() async throws {
        for sample in [try fixture(prerelease: true), try fixture(corruptPackage: true)] {
            let network = UpdateFixtureNetwork(responses: sample.responses), relay = UpdateFixtureRelay()
            let coordinator = UpdateCoordinator(root: try temporaryRoot(), currentVersion: "0.3.0", publicKey: sample.key,
                dataLoader: { try await network.load($0, maximum: $1) }, upload: { try await relay.upload($0, name: $1, settings: $2) })
            coordinator.ftpSettings = { FTPSettings(host: "127.0.0.1", username: "synthetic", directory: "/") }
            await coordinator.checkNow()
            XCTAssertNil(coordinator.candidateVersion); XCTAssertFalse(coordinator.canInstall)
            XCTAssertTrue(coordinator.status.contains("失败"))
            let snapshot = await relay.snapshot(); XCTAssertTrue(snapshot.0.isEmpty)
        }
    }
    @MainActor func testPinnedSparkleVersionRejectsWrongFeedTarget() throws {
        XCTAssertNoThrow(try AppUpdater.validateTarget(actual: "0.4.0", approved: "0.4.0"))
        XCTAssertThrowsError(try AppUpdater.validateTarget(actual: "0.4.1", approved: "0.4.0"))
        XCTAssertThrowsError(try AppUpdater.validateTarget(actual: "0.3.0", approved: "0.4.0"))
        XCTAssertThrowsError(try AppUpdater.validateTarget(actual: "0.4.0", approved: nil))
    }
    @MainActor func testFreshInstallationRejectsOlderSignedRelease() async throws {
        let sample = try fixture(version: "0.2.0"), network = UpdateFixtureNetwork(responses: sample.responses)
        let coordinator = UpdateCoordinator(root: try temporaryRoot(), currentVersion: "0.3.0", publicKey: sample.key,
            dataLoader: { try await network.load($0, maximum: $1) })
        await coordinator.checkNow()
        XCTAssertNil(coordinator.candidateVersion)
        let count = await network.count()
        XCTAssertEqual(count, 1)
        XCTAssertTrue(coordinator.status.contains("失败"))
    }
    @MainActor func testNoPublishedReleaseIsSuccessfulDailyCheckWithoutPopupOrRetry() async throws {
        let sample = try fixture(), root = try temporaryRoot()
        let coordinator = UpdateCoordinator(root: root, currentVersion: "0.3.0", publicKey: sample.key,
            dataLoader: { _, _ in throw UpdateHTTPFailure.status(404) })
        await coordinator.checkNow()
        XCTAssertEqual(coordinator.status, "暂无正式更新；测试版请手动下载")
        XCTAssertFalse(coordinator.canInstall)
        let bytes = try Data(contentsOf: root.appendingPathComponent("Updates/state.json"))
        let persisted = try JSONDecoder().decode(UpdatePersistentState.self, from: bytes)
        XCTAssertNotNil(persisted.schedule.completedWindow)
        XCTAssertNil(persisted.schedule.retryAfter)
        XCTAssertEqual(persisted.schedule.failureCount, 0)
    }
    @MainActor func testRepeatedManualNoReleaseChecksEachCompleteAndReportTheirResult() async throws {
        let sample = try fixture(), network = UpdateFixtureHTTPFailureNetwork(status: 404)
        let coordinator = UpdateCoordinator(root: try temporaryRoot(), currentVersion: "0.3.0", publicKey: sample.key,
            dataLoader: { try await network.load($0, maximum: $1) })
        var logs: [(String, Bool)] = []
        coordinator.writeLog = { logs.append(($0, $1)) }
        XCTAssertNil(coordinator.lastCheckCompletedAt)
        await coordinator.checkNow()
        let firstCompletion = try XCTUnwrap(coordinator.lastCheckCompletedAt)
        XCTAssertEqual(logs.count, 2, "一次手动检查应各记录一次开始和完成")
        XCTAssertTrue(logs.allSatisfy { !$0.1 })
        XCTAssertTrue(try XCTUnwrap(logs.last).0.contains("暂无正式更新"))
        XCTAssertTrue(try XCTUnwrap(logs.last).0.contains("测试版请手动下载"))
        XCTAssertFalse(coordinator.canInstall)
        XCTAssertTrue(coordinator.canCheck)

        try await Task.sleep(nanoseconds: 10_000_000)
        // Exercise the same entry point as the visible button after this daily
        // window has already completed. Manual checks must still make a request.
        coordinator.check()
        for _ in 0..<100 {
            if let completed = coordinator.lastCheckCompletedAt, completed > firstCompletion, !coordinator.isChecking { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertGreaterThan(try XCTUnwrap(coordinator.lastCheckCompletedAt), firstCompletion)
        let requests = await network.count()
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(logs.count, 4, "重复结果也应有独立的开始和完成记录")
        XCTAssertTrue(logs.allSatisfy { !$0.1 })
        XCTAssertFalse(coordinator.isChecking)
        XCTAssertTrue(coordinator.canCheck)
    }
    @MainActor func testBackgroundNoReleaseCheckUpdatesCompletionWithoutManualLogsOrInstallation() async throws {
        let sample = try fixture(), network = UpdateFixtureHTTPFailureNetwork(status: 404)
        let coordinator = UpdateCoordinator(root: try temporaryRoot(), currentVersion: "0.3.0", publicKey: sample.key,
            dataLoader: { try await network.load($0, maximum: $1) })
        var logs: [(String, Bool)] = [], installs = 0
        coordinator.writeLog = { logs.append(($0, $1)) }
        coordinator.install = { _ in installs += 1; return true }
        coordinator.start()
        for _ in 0..<100 {
            if coordinator.lastCheckCompletedAt != nil && !coordinator.isChecking { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(coordinator.lastCheckCompletedAt)
        XCTAssertEqual(coordinator.status, "暂无正式更新；测试版请手动下载")
        XCTAssertTrue(logs.isEmpty, "后台无正式版本不应记录手动检查日志")
        XCTAssertEqual(installs, 0)
        XCTAssertFalse(coordinator.waitingForInstallation)
        XCTAssertFalse(coordinator.canInstall)
        let requests = await network.count()
        XCTAssertEqual(requests, 1)
    }
    @MainActor func testHTTPFailuresHaveReadableStatusAndCompletionFeedback() async throws {
        let sample = try fixture()
        for status in [403, 500] {
            XCTAssertTrue(UpdateHTTPFailure.status(status).localizedDescription.contains("HTTP \(status)"))
            let root = try temporaryRoot(), network = UpdateFixtureHTTPFailureNetwork(status: status)
            let coordinator = UpdateCoordinator(root: root, currentVersion: "0.3.0", publicKey: sample.key,
                dataLoader: { try await network.load($0, maximum: $1) })
            var logs: [(String, Bool)] = []
            coordinator.writeLog = { logs.append(($0, $1)) }
            await coordinator.checkNow()
            XCTAssertTrue(coordinator.status.contains("HTTP \(status)"))
            XCTAssertNotNil(coordinator.lastCheckCompletedAt, "失败也应明确完成本次手动检查")
            XCTAssertEqual(logs.count, 2, "手动失败不应在 catch 和完成通知中重复记录错误")
            XCTAssertFalse(try XCTUnwrap(logs.first).1)
            XCTAssertTrue(try XCTUnwrap(logs.last).1)
            XCTAssertTrue(try XCTUnwrap(logs.last).0.contains("HTTP \(status)"))
            XCTAssertTrue(coordinator.canCheck)
            XCTAssertFalse(coordinator.canInstall)
            let state = try JSONDecoder().decode(UpdatePersistentState.self, from: Data(contentsOf: root.appendingPathComponent("Updates/state.json")))
            XCTAssertEqual(state.schedule.failureCount, 1)
            XCTAssertNotNil(state.schedule.retryAfter)
        }
    }
    @MainActor func testConcurrentManualNoReleaseChecksDisableTheButtonAndProduceOneResult() async throws {
        let sample = try fixture(), network = UpdateFixtureHTTPFailureNetwork(status: 404, blocked: true)
        let coordinator = UpdateCoordinator(root: try temporaryRoot(), currentVersion: "0.3.0", publicKey: sample.key,
            dataLoader: { try await network.load($0, maximum: $1) })
        var logs: [(String, Bool)] = []
        coordinator.writeLog = { logs.append(($0, $1)) }
        let first = Task { await coordinator.checkNow() }
        for _ in 0..<100 {
            if await network.count() > 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(coordinator.isChecking)
        XCTAssertFalse(coordinator.canCheck)
        XCTAssertNil(coordinator.lastCheckCompletedAt)
        var secondStarted = false
        let second = Task { secondStarted = true; await coordinator.checkNow() }
        for _ in 0..<100 {
            if secondStarted { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let requestCount = await network.count()
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(logs.count, 1, "被合并的手动点击不能重复记录开始")
        await network.release()
        await first.value; await second.value
        let finalRequestCount = await network.count()
        XCTAssertEqual(finalRequestCount, 1)
        XCTAssertNotNil(coordinator.lastCheckCompletedAt)
        XCTAssertEqual(logs.count, 2)
        XCTAssertFalse(coordinator.isChecking)
        XCTAssertTrue(coordinator.canCheck)
    }
    @MainActor func testConcurrentCheckRequestsAreCoalesced() async throws {
        let sample = try fixture(), network = UpdateFixtureNetwork(responses: sample.responses)
        let coordinator = UpdateCoordinator(root: try temporaryRoot(), currentVersion: "0.3.0", publicKey: sample.key,
            dataLoader: { try await Task.sleep(nanoseconds: 5_000_000); return try await network.load($0, maximum: $1) })
        async let first: Void = coordinator.checkNow()
        async let second: Void = coordinator.checkNow()
        _ = await (first, second)
        let count = await network.count()
        XCTAssertEqual(count, 7, "一次metadata、清单、签名和四个附件，不得并发重复下载")
    }

    @MainActor func testIsolatedTestDiscoversMacOnlyReleaseWithoutFTPOrPrematureInstallation() async throws {
        let sample = try fixture(version: "0.1.4", prerelease: true, manifestChannel: "test", tagPrefix: "update-test-v", macOnly: true)
        let network = UpdateFixtureNetwork(responses: sample.responses), relay = UpdateFixtureRelay()
        var ftpReads = 0, installs = 0
        let coordinator = UpdateCoordinator(root: try temporaryRoot(), currentVersion: "0.1.3", publicKey: sample.key,
            channel: .isolatedTest(), dataLoader: { try await network.load($0, maximum: $1) },
            upload: { try await relay.upload($0, name: $1, settings: $2) })
        coordinator.ftpSettings = { ftpReads += 1; return FTPSettings(host: "127.0.0.1", username: "synthetic", directory: "/share") }
        coordinator.install = { _ in installs += 1; return true }
        await coordinator.checkNow()
        XCTAssertEqual(coordinator.candidateVersion, "0.1.4")
        XCTAssertTrue(coordinator.canInstall)
        XCTAssertFalse(coordinator.waitingForInstallation)
        XCTAssertFalse(coordinator.isRelaying)
        XCTAssertTrue(coordinator.relayStatus.contains("不转发 FTP"))
        XCTAssertEqual(installs, 0)
        let urls = await network.urls()
        XCTAssertEqual(urls.count, 5, "测试通道只下载metadata、签名清单和两个Mac附件")
        XCTAssertEqual(urls.first, "https://api.github.com/repos/DB-XiaoQiang/shanchuan/releases/tags/update-test-v0.1.4")
        XCTAssertTrue(urls.dropFirst().allSatisfy { $0.hasPrefix("https://github.com/DB-XiaoQiang/shanchuan/releases/download/update-test-v0.1.4/") })
        XCTAssertFalse(urls.contains { $0.contains("win-x64") })
        coordinator.start()
        coordinator.tick()
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(ftpReads, 0, "测试通道连FTP配置凭据回调也不能读取")
        let uploaded = await relay.snapshot()
        XCTAssertTrue(uploaded.0.isEmpty)
    }

    @MainActor func testIsolatedTestMacOnlyCacheRestoresWithoutWindowsFeedOrNetwork() async throws {
        let sample = try fixture(version: "0.1.4", prerelease: true, manifestChannel: "test", tagPrefix: "update-test-v", macOnly: true)
        let root = try temporaryRoot(), network = UpdateFixtureNetwork(responses: sample.responses)
        var first: UpdateCoordinator? = UpdateCoordinator(root: root, currentVersion: "0.1.3", publicKey: sample.key,
            channel: .isolatedTest(), dataLoader: { try await network.load($0, maximum: $1) })
        await first!.checkNow()
        XCTAssertEqual(first!.candidateVersion, "0.1.4")
        first = nil
        let restored = UpdateCoordinator(root: root, currentVersion: "0.1.3", publicKey: sample.key,
            channel: .isolatedTest(), dataLoader: { _, _ in XCTFail("缓存恢复不应再次查询网络"); return Data() })
        restored.ftpSettings = { XCTFail("缓存恢复不能读取FTP设置"); return nil }
        restored.start()
        XCTAssertEqual(restored.candidateVersion, "0.1.4")
        XCTAssertTrue(restored.canInstall)
        try await Task.sleep(nanoseconds: 30_000_000)

        let production = UpdateCoordinator(root: root, currentVersion: "0.1.3", publicKey: sample.key,
            dataLoader: { _, _ in XCTFail("正式通道不能把测试缓存变成请求"); return Data() })
        production.start()
        XCTAssertNil(production.candidateVersion, "即使公钥误配一致，正式通道也必须拒绝test清单")
        XCTAssertFalse(production.canInstall)
    }

    @MainActor func testTestChannelRejectsWrongMetadataChannelTamperingAndDowngrade() async throws {
        let samples = [
            try fixture(version: "0.1.4", prerelease: false, manifestChannel: "test", tagPrefix: "update-test-v", macOnly: true),
            try fixture(version: "0.1.4", prerelease: true, manifestChannel: "test", tagPrefix: "v", macOnly: true),
            try fixture(version: "0.1.4", prerelease: true, manifestChannel: "test", tagPrefix: "update-test-v", macOnly: true, draft: true),
            try fixture(version: "0.1.4", prerelease: true, manifestChannel: "stable", tagPrefix: "update-test-v", macOnly: true),
            try fixture(version: "0.1.4", prerelease: true, corruptPackage: true, manifestChannel: "test", tagPrefix: "update-test-v", macOnly: true)
        ]
        for sample in samples {
            let network = UpdateFixtureNetwork(responses: sample.responses)
            let coordinator = UpdateCoordinator(root: try temporaryRoot(), currentVersion: "0.1.3", publicKey: sample.key,
                channel: .isolatedTest(), dataLoader: { try await network.load($0, maximum: $1) })
            coordinator.ftpSettings = { XCTFail("拒绝的测试发行版不能读取FTP设置"); return nil }
            await coordinator.checkNow()
            XCTAssertNil(coordinator.candidateVersion)
            XCTAssertFalse(coordinator.canInstall)
            XCTAssertTrue(coordinator.status.contains("失败"))
        }
        let sample = try fixture(version: "0.1.4", prerelease: true, manifestChannel: "test", tagPrefix: "update-test-v", macOnly: true)
        let network = UpdateFixtureNetwork(responses: sample.responses)
        let newer = UpdateCoordinator(root: try temporaryRoot(), currentVersion: "0.1.5", publicKey: sample.key,
            channel: .isolatedTest(), dataLoader: { try await network.load($0, maximum: $1) })
        await newer.checkNow()
        XCTAssertFalse(newer.canInstall)
        XCTAssertTrue(newer.status.contains("拒绝低于当前安装版本"))
        let requests = await network.count()
        XCTAssertEqual(requests, 1)
    }

    @MainActor func testProductionAndTestManifestChannelsAndKeysAreMutuallyRejected() throws {
        let stable = try fixture(), test = try fixture(version: "0.1.4", prerelease: true, manifestChannel: "test", tagPrefix: "update-test-v", macOnly: true)
        let bytes = try XCTUnwrap(test.responses["update-manifest.json"]), signature = try XCTUnwrap(test.responses["update-manifest.sig"])
        XCTAssertThrowsError(try UpdateVerifier.verify(manifest: bytes, signature: signature, publicKeyPEM: test.key))
        XCTAssertThrowsError(try UpdateVerifier.verify(manifest: bytes, signature: signature, publicKeyPEM: stable.key, expectedChannel: "test"))
        XCTAssertThrowsError(try UpdateVerifier.verify(manifest: bytes, signature: signature, publicKeyPEM: test.key, expectedChannel: "preview"))
        XCTAssertNoThrow(try UpdateVerifier.verify(manifest: bytes, signature: signature, publicKeyPEM: test.key, expectedChannel: "test"))
        XCTAssertThrowsError(try UpdateVerifier.verify(manifest: XCTUnwrap(stable.responses["update-manifest.json"]),
            signature: XCTUnwrap(stable.responses["update-manifest.sig"]), publicKeyPEM: stable.key, expectedChannel: "test"))
        XCTAssertEqual(UpdateChannel.production.sparkleFeedURL(version: "0.1.4"), "https://github.com/DB-XiaoQiang/shanchuan/releases/download/v0.1.4/appcast.xml")
        XCTAssertEqual(UpdateChannel.isolatedTest().sparkleFeedURL(version: "0.1.4"), "https://github.com/DB-XiaoQiang/shanchuan/releases/download/update-test-v0.1.4/appcast.xml")
    }

    @MainActor func testInvalidTestChannelIsDisabledWithoutFallingBackToProduction() async throws {
        let sample = try fixture()
        let coordinator = UpdateCoordinator(root: try temporaryRoot(), currentVersion: "0.1.3", publicKey: sample.key,
            channel: .isolatedTest(targetVersion: "../../latest"), dataLoader: { _, _ in XCTFail("无效测试配置不能访问任何网络"); return Data() })
        coordinator.start()
        await coordinator.checkNow()
        XCTAssertFalse(coordinator.canCheck)
        XCTAssertFalse(coordinator.canInstall)
        XCTAssertTrue(coordinator.status.contains("测试更新目标配置无效"))
    }
}
