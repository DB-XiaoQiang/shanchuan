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
    private func fixture(version: String = "0.4.0", prerelease: Bool = false, corruptPackage: Bool = false) throws -> Fixture {
        let signingKey = P256.Signing.PrivateKey()
        let package = Data("windows package".utf8), zip = Data("macos synthetic zip".utf8), appcast = Data("<rss/>".utf8)
        let fullName = "Shanchuan-\(version)-win-x64-full.nupkg"
        let feed = try JSONSerialization.data(withJSONObject: ["Assets": [["PackageId": "Shanchuan", "FileName": fullName,
            "Version": version, "Type": "Full", "Size": package.count, "SHA256": UpdateVerifier.sha256(package)]]])
        func asset(_ platform: String, _ arch: String, _ kind: String, _ name: String, _ bytes: Data) -> [String: Any] {
            ["platform": platform, "arch": arch, "kind": kind, "name": name, "size": bytes.count, "sha256": UpdateVerifier.sha256(bytes)]
        }
        let manifest = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "product": "Shanchuan", "channel": "stable", "version": version, "releaseNotes": "合成更新说明",
            "assets": [asset("windows", "x64", "velopack-full", fullName, package),
                       asset("windows", "x64", "velopack-feed", "releases.win-x64.json", feed),
                       asset("macos", "arm64", "sparkle-zip", "Shanchuan-macos-arm64.zip", zip),
                       asset("macos", "arm64", "appcast", "appcast.xml", appcast)]
        ], options: [.sortedKeys])
        return Fixture(key: signingKey.publicKey.pemRepresentation, responses: [
            "latest": try JSONSerialization.data(withJSONObject: ["tag_name": "v" + version, "draft": false, "prerelease": prerelease]),
            "update-manifest.json": manifest, "update-manifest.sig": try signingKey.signature(for: manifest).derRepresentation,
            fullName: corruptPackage ? Data("CORRUPTED".utf8) : package,
            "releases.win-x64.json": feed, "Shanchuan-macos-arm64.zip": zip, "appcast.xml": appcast
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
        XCTAssertEqual(coordinator.status, "暂无正式更新")
        XCTAssertFalse(coordinator.canInstall)
        let bytes = try Data(contentsOf: root.appendingPathComponent("Updates/state.json"))
        let persisted = try JSONDecoder().decode(UpdatePersistentState.self, from: bytes)
        XCTAssertNotNil(persisted.schedule.completedWindow)
        XCTAssertNil(persisted.schedule.retryAfter)
        XCTAssertEqual(persisted.schedule.failureCount, 0)
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
}
