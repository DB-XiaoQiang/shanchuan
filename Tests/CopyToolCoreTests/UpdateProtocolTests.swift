import XCTest
import CryptoKit
@testable import CopyToolCore

final class UpdateProtocolTests: XCTestCase {
    private var fixtureRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Updates")
    }
    private func signed(_ object: [String: Any], key: P256.Signing.PrivateKey = .init()) throws -> VerifiedRelease { // gitleaks:allow -- ephemeral in-memory test key, no embedded private bytes
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try UpdateVerifier.verify(manifest: data, signature: key.signature(for: data).derRepresentation,
            publicKeyPEM: key.publicKey.pemRepresentation)
    }
    private func manifest(name: String = "update.nupkg", platform: String = "windows", sha: String = String(repeating: "a", count: 64)) -> [String: Any] {
        ["schemaVersion": 1, "product": "Shanchuan", "channel": "stable", "version": "0.3.0", "releaseNotes": "说明",
         "assets": [["platform": platform, "arch": "x64", "kind": "velopack-full", "name": name, "size": 3, "sha256": sha]]]
    }
    func testSharedCrossPlatformSignatureAndPayload() throws {
        let bytes = try Data(contentsOf: fixtureRoot.appendingPathComponent("manifest.json"))
        let signature = try Data(contentsOf: fixtureRoot.appendingPathComponent("manifest.sig"))
        let key = try String(contentsOf: fixtureRoot.appendingPathComponent("public-key.pem"), encoding: .utf8)
        let release = try UpdateVerifier.verify(manifest: bytes, signature: signature, publicKeyPEM: key)
        XCTAssertEqual(release.manifest.version, "9.8.7")
        XCTAssertEqual(release.identity, UpdateVerifier.sha256(bytes))
        try UpdateVerifier.verify(file: fixtureRoot.appendingPathComponent("payload.bin"), asset: XCTUnwrap(release.manifest.assets.first))
        var tampered = bytes; tampered[0] ^= 1
        XCTAssertThrowsError(try UpdateVerifier.verify(manifest: tampered, signature: signature, publicKeyPEM: key))
        XCTAssertThrowsError(try UpdateVerifier.verify(manifest: bytes, signature: signature, publicKeyPEM: P256.Signing.PrivateKey().publicKey.pemRepresentation))
        XCTAssertThrowsError(try UpdateVerifier.verify(manifest: bytes, signature: signature.prefix(10), publicKeyPEM: key))
    }
    func testRejectsSignedTraversalWrongPlatformAndMalformedManifest() throws {
        for name in ["../update.nupkg", "/update.nupkg", "update\\file", "a/../b", ".hidden", "中文.zip"] {
            XCTAssertThrowsError(try signed(manifest(name: name)), name)
        }
        XCTAssertThrowsError(try signed(manifest(platform: "linux")))
        XCTAssertThrowsError(try signed(manifest(sha: "ABCD")))
        var wrong = manifest()
        var badAssets = wrong["assets"] as! [[String: Any]]
        badAssets[0]["arch"] = "arm64"; wrong["assets"] = badAssets; XCTAssertThrowsError(try signed(wrong))
        wrong = manifest(); badAssets = wrong["assets"] as! [[String: Any]]
        badAssets[0]["kind"] = "sparkle-zip"; wrong["assets"] = badAssets; XCTAssertThrowsError(try signed(wrong))
        wrong = manifest(); badAssets = wrong["assets"] as! [[String: Any]]
        var duplicate = badAssets[0]; duplicate["name"] = "UPDATE.NUPKG"; duplicate["kind"] = "setup"
        badAssets.append(duplicate); wrong["assets"] = badAssets; XCTAssertThrowsError(try signed(wrong))
        wrong = manifest(); wrong["product"] = "Other"; XCTAssertThrowsError(try signed(wrong))
        wrong = manifest(); wrong["channel"] = "beta"; XCTAssertThrowsError(try signed(wrong))
        wrong = manifest(); wrong["version"] = "0.3.0-rc.1"; XCTAssertThrowsError(try signed(wrong))
        wrong = manifest(); wrong["assets"] = [Any](); XCTAssertThrowsError(try signed(wrong))
        wrong = manifest(); wrong["schemaVersion"] = 2; XCTAssertThrowsError(try signed(wrong))
    }
    func testFileSizeAndDigestPreventTruncatedOrTamperedPackage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("update.nupkg")
        let asset = try XCTUnwrap(signed(manifest(sha: UpdateVerifier.sha256(Data("abc".utf8)))).manifest.assets.first)
        try Data("abc".utf8).write(to: file); try UpdateVerifier.verify(file: file, asset: asset)
        try Data("ab".utf8).write(to: file); XCTAssertThrowsError(try UpdateVerifier.verify(file: file, asset: asset))
        try Data("xyz".utf8).write(to: file); XCTAssertThrowsError(try UpdateVerifier.verify(file: file, asset: asset))
    }
    func testNumericVersionComparisonAndInvalidInputs() throws {
        XCTAssertLessThan(try ReleaseVersion("0.9.9"), try ReleaseVersion("0.10.0"))
        XCTAssertEqual(try ReleaseVersion("0.3.0"), try ReleaseVersion("0.3.0"))
        for value in ["1", "1.2", "01.2.3", "1.2.3.4", "v1.2.3", "1.2.-1", "1.2.3-beta"] {
            XCTAssertThrowsError(try ReleaseVersion(value), value)
        }
    }
    func testOneOClockCatchUpAndPersistedBackoff() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        func date(_ text: String) -> Date {
            let parser = ISO8601DateFormatter(); return parser.date(from: text + "+08:00")!
        }
        var schedule = UpdateCheckSchedule()
        let before = date("2026-11-12T00:59:00"), first = date("2026-11-12T01:00:00")
        XCTAssertTrue(schedule.isDue(at: before, calendar: calendar))
        schedule.succeeded(at: before, calendar: calendar)
        XCTAssertFalse(schedule.isDue(at: before.addingTimeInterval(30), calendar: calendar))
        XCTAssertTrue(schedule.isDue(at: first, calendar: calendar))
        schedule.succeeded(at: first, calendar: calendar)
        XCTAssertFalse(schedule.isDue(at: date("2026-11-12T23:59:00"), calendar: calendar))
        XCTAssertTrue(schedule.isDue(at: date("2026-11-14T09:00:00"), calendar: calendar))
        var now = date("2026-11-14T09:00:00")
        for seconds in [60.0, 300, 900, 3600, 3600] {
            schedule.failed(at: now)
            XCTAssertEqual(schedule.retryAfter, now.addingTimeInterval(seconds))
            XCTAssertFalse(schedule.isDue(at: now.addingTimeInterval(seconds - 1), calendar: calendar))
            XCTAssertTrue(schedule.isDue(at: now.addingTimeInterval(seconds), calendar: calendar))
            schedule = try JSONDecoder().decode(UpdateCheckSchedule.self, from: JSONEncoder().encode(schedule))
            now = now.addingTimeInterval(seconds)
        }
        schedule.succeeded(at: now, calendar: calendar)
        XCTAssertNil(schedule.retryAfter); XCTAssertEqual(schedule.failureCount, 0)
    }
    func testSignedFeedMustSelectExactlyMatchingFullPackage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let package = Data("abc".utf8)
        let feedObject: [String: Any] = ["Assets": [["PackageId": "Shanchuan", "FileName": "update.nupkg", "Version": "0.3.0", "Type": "Full", "Size": 3,
            "SHA256": UpdateVerifier.sha256(package)]]]
        let feed = try JSONSerialization.data(withJSONObject: feedObject)
        var object = manifest(sha: UpdateVerifier.sha256(package))
        var assets = object["assets"] as! [[String: Any]]
        assets.append(["platform": "windows", "arch": "x64", "kind": "velopack-feed", "name": "releases.win-x64.json", "size": feed.count, "sha256": UpdateVerifier.sha256(feed)])
        object["assets"] = assets
        let release = try signed(object)
        try package.write(to: root.appendingPathComponent("update.nupkg")); try feed.write(to: root.appendingPathComponent("releases.win-x64.json"))
        try UpdateVerifier.verifyWindowsFeed(release, directory: root)
        try Data("{\"Assets\":[]}".utf8).write(to: root.appendingPathComponent("releases.win-x64.json"))
        XCTAssertThrowsError(try UpdateVerifier.verifyWindowsFeed(release, directory: root))
    }
}
