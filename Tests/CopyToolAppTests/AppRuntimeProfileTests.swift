import XCTest
import CopyToolCore
@testable import CopyToolApp

final class AppRuntimeProfileTests: XCTestCase {
    private var validTestProfile: AppRuntimeProfile {
        AppRuntimeProfile.load(info: ["ShanchuanUpdateTest": true, "ShanchuanUpdateTestTargetVersion": "0.1.4"],
            bundleIdentifier: AppRuntimeProfile.testBundleIdentifier)
    }

    func testProductionProfileRetainsOriginalDirectoriesAndChannel() {
        let profile = AppRuntimeProfile.load(info: [:], bundleIdentifier: "local.copytool.independent")
        XCTAssertEqual(profile, .production)
        XCTAssertEqual(profile.dataDirectoryName, "CopyToolIndependent")
        XCTAssertEqual(profile.applicationName, "闪传")
        XCTAssertTrue(profile.allowsBusinessTransfers)
        XCTAssertTrue(profile.updatesEnabled)
        XCTAssertFalse(profile.updateChannel.isTest)
        XCTAssertTrue(profile.updateChannel.metadataURL.path.hasSuffix("/latest"))
    }

    func testTestProfileUsesSeparateIdentityDirectoryAndTestOnlyChannel() {
        let profile = validTestProfile
        XCTAssertTrue(profile.isUpdateTest)
        XCTAssertNil(profile.configurationError)
        XCTAssertEqual(profile.applicationName, "闪传更新测试")
        XCTAssertEqual(profile.dataDirectoryName, "CopyToolUpdateTest")
        XCTAssertNotEqual(profile.dataRoot, AppRuntimeProfile.production.dataRoot)
        XCTAssertFalse(profile.allowsBusinessTransfers)
        XCTAssertTrue(profile.updateChannel.isTest)
        XCTAssertEqual(profile.updateChannel.expectedManifestChannel, "test")
        XCTAssertTrue(profile.updateChannel.metadataURL.path.hasSuffix("/tags/update-test-v0.1.4"))
        XCTAssertFalse(profile.updateChannel.allowsRelay)
    }

    func testMalformedTestMarkersRemainIsolatedAndDisableUpdates() {
        let cases: [([String: Any], String?)] = [
            (["ShanchuanUpdateTest": true, "ShanchuanUpdateTestTargetVersion": "0.1.4"], "local.copytool.independent"),
            ([:], AppRuntimeProfile.testBundleIdentifier),
            (["ShanchuanUpdateTest": false, "ShanchuanUpdateTestTargetVersion": "0.1.4"], AppRuntimeProfile.testBundleIdentifier),
            (["ShanchuanUpdateTest": true, "ShanchuanUpdateTestTargetVersion": "0.1.5"], AppRuntimeProfile.testBundleIdentifier),
            (["ShanchuanUpdateTest": "true", "ShanchuanUpdateTestTargetVersion": "0.1.4"], AppRuntimeProfile.testBundleIdentifier)
        ]
        for (info, identifier) in cases {
            let profile = AppRuntimeProfile.load(info: info, bundleIdentifier: identifier)
            XCTAssertTrue(profile.isUpdateTest)
            XCTAssertFalse(profile.updatesEnabled)
            XCTAssertFalse(profile.allowsBusinessTransfers)
            XCTAssertEqual(profile.dataDirectoryName, "CopyToolUpdateTest")
            XCTAssertTrue(profile.updateChannel.isTest)
            XCTAssertNotNil(profile.updateChannel.configurationError)
        }
    }

    @MainActor
    func testIsolatedModelNeverUsesProductionPasswordHooksOrQueuesBusinessWork() throws {
        try withRoot { root in
            var settings = AppPreferences()
            settings.host = "127.0.0.1"; settings.username = "synthetic"
            settings.shortcuts.enabled = true
            try JSONEncoder().encode(settings).write(to: root.appendingPathComponent("preferences.json"))
            var passwordReads = 0, passwordWrites = 0, notices = 0
            let model = AppModel(root: root, readPassword: { passwordReads += 1; return "must-not-read" },
                writePassword: { _ in passwordWrites += 1 }, sendFailureNotice: { _ in notices += 1 },
                runtimeProfile: validTestProfile)
            XCTAssertEqual(passwordReads, 0)
            XCTAssertEqual(model.password, "")
            XCTAssertFalse(model.preferences.shortcuts.enabled)
            XCTAssertFalse(model.shortcutPermissionGranted)
            model.password = "synthetic-memory-value"
            model.enqueue(HistoryEntry(kind: .text, content: "must not send"))
            model.addFiles([URL(fileURLWithPath: "/nonexistent-synthetic")], automatic: false)
            model.add(HistoryEntry(kind: .text, content: "must not capture"), automatic: false)
            model.sendValidationSamples()
            model.copyInFrontmostApplication()
            model.pasteInFrontmostApplication()
            model.captureClipboardForShortcut(expectedChangeCount: -1)
            model.migrateOriginalFTP()
            XCTAssertTrue(model.entries.isEmpty)
            XCTAssertEqual(model.queued, 0)
            XCTAssertFalse(model.transferSnapshot.isActive)
            XCTAssertEqual(passwordReads, 0)
            XCTAssertEqual(passwordWrites, 0)
            XCTAssertEqual(notices, 0)
            XCTAssertFalse(model.settingsError.isEmpty)
        }
    }

    @MainActor
    func testLocalTestRulesCanPersistWithoutSavingAnyFTPPassword() throws {
        try withRoot { root in
            var passwordWrites = 0
            let model = AppModel(root: root, writePassword: { _ in passwordWrites += 1 }, runtimeProfile: validTestProfile)
            var candidate = model.preferences
            candidate.directoryExclusionRules = "# synthetic test rules\ncache/\n*.tmp"
            XCTAssertTrue(model.saveSettings(preferences: candidate, password: ""))
            let saved = try JSONDecoder().decode(AppPreferences.self, from: Data(contentsOf: root.appendingPathComponent("preferences.json")))
            XCTAssertEqual(saved.directoryExclusionRules, candidate.directoryExclusionRules)
            XCTAssertFalse(saved.shortcuts.enabled)
            XCTAssertFalse(model.saveSettings(preferences: candidate, password: "not-a-real-password"))
            XCTAssertEqual(passwordWrites, 0)
        }
    }

    @MainActor
    private func withRoot(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ShanchuanRuntimeProfile-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
}
