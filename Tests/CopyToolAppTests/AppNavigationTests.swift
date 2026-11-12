import XCTest
import CopyToolCore
@testable import CopyToolApp

@MainActor private final class TestVault {
    var password = "synthetic-initial-password"
    var writes = 0
}

final class AppNavigationTests: XCTestCase {
    @MainActor
    func testConfigurationNavigationFlushesLatestEditAndPreservesInvalidDraft() throws {
        try withModel { model, _ in
            let session = SettingsPageSession()
            let navigation = AppNavigation()
            session.connect(model: model)
            navigation.prepareToLeaveSettings = { session.prepareToLeave() }
            XCTAssertTrue(navigation.select(.settings))
            session.autosave.portText = "not-a-port"
            session.autosave.schedule()
            XCTAssertFalse(navigation.select(.logs))
            XCTAssertEqual(navigation.page, .settings)
            XCTAssertEqual(session.autosave.portText, "not-a-port")
            XCTAssertEqual(model.preferences.port, 21)

            // Recreating the page reconnects the same session rather than discarding its draft.
            session.connect(model: model)
            XCTAssertEqual(session.autosave.portText, "not-a-port")
            session.autosave.portText = "2121"
            session.autosave.schedule()
            XCTAssertTrue(navigation.select(.logs))
            XCTAssertEqual(model.preferences.port, 2121)
            XCTAssertEqual(navigation.page, .logs)
            let saved = try JSONDecoder().decode(AppPreferences.self,
                from: Data(contentsOf: model.root.appendingPathComponent("preferences.json")))
            XCTAssertEqual(saved.port, 2121)
        }
    }

    @MainActor
    func testSwitchingBackToSettingsDoesNotRestoreAnOutdatedPasswordOrWriteVaultTwice() throws {
        try withModel { model, vault in
            let session = SettingsPageSession()
            session.connect(model: model)
            session.autosave.secret = "synthetic-changed-password"
            session.autosave.schedule()
            XCTAssertTrue(session.prepareToLeave())
            session.connect(model: model)
            XCTAssertEqual(session.autosave.secret, model.password)
            XCTAssertEqual(model.password, "synthetic-changed-password")
            XCTAssertTrue(session.prepareToLeave())
            XCTAssertEqual(vault.writes, 1)
        }
    }

    @MainActor
    func testFileDropIsRestrictedToHistoryAndLeavingSettingsCanBeCancelled() {
        let navigation = AppNavigation()
        XCTAssertTrue(navigation.acceptsFileDrop)
        for page in [AppNavigation.Page.logs, .settings, .about] {
            XCTAssertTrue(navigation.select(page))
            XCTAssertFalse(navigation.acceptsFileDrop)
        }
        XCTAssertTrue(navigation.select(.settings))
        var attempts = 0
        navigation.prepareToLeaveSettings = { attempts += 1; return false }
        XCTAssertTrue(navigation.select(.settings))
        XCTAssertEqual(attempts, 0)
        XCTAssertFalse(navigation.select(.history))
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(navigation.page, .settings)
        XCTAssertFalse(navigation.prepareToLeaveCurrentPage())
    }

    @MainActor
    private func withModel(_ body: (AppModel, TestVault) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ShanchuanSettingsPage-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var preferences = AppPreferences()
        preferences.host = "synthetic.invalid"
        preferences.username = "synthetic"
        preferences.shortcuts.enabled = false
        try JSONEncoder().encode(preferences).write(to: root.appendingPathComponent("preferences.json"))
        let vault = TestVault()
        let model = AppModel(root: root, readPassword: { vault.password }, writePassword: { vault.password = $0; vault.writes += 1 })
        try body(model, vault)
    }
}
