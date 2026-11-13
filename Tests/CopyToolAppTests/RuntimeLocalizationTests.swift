import XCTest
@testable import CopyToolCore
@testable import CopyToolApp

final class RuntimeLocalizationTests: XCTestCase {
    @MainActor func testExistingCurrentStatesRelocalizeAfterEvictionWithoutChangingLogsOrDrafts() throws {
        let name = "Shanchuan.RuntimeLocalizationTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let previous = L10n.language
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            L10n.setLanguage(previous, defaults: defaults)
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: root)
        }
        L10n.setLanguage(.simplifiedChinese, defaults: defaults)
        let profile = AppRuntimeProfile.load(info: ["ShanchuanUpdateTest": true,
            "ShanchuanUpdateTestTargetVersion": "0.1.4"], bundleIdentifier: AppRuntimeProfile.testBundleIdentifier)
        let model = AppModel(root: root, runtimeProfile: profile)
        model.logLocalized(L10n.snapshotFormat("正在下载更新：%@", "配置中心.zip"))
        let userLiteral = L10n.format("%@%@", "更新", "")
        _ = L10n.text("更新")
        model.settingsError = userLiteral
        let history = model.transferLogs
        let preferences = model.preferences
        let updates = UpdateCoordinator(root: root, publicKey: "synthetic")
        let connection = FTPConnectionTestStore()
        connection.test(input: .init(host: "", portText: "21", username: "synthetic", password: "", directory: "/"))
        let autosave = SettingsAutosaveStore()
        autosave.connect(current: { (preferences, "") }, save: { _, _ in nil })
        autosave.portText = "invalid"
        autosave.flush()
        for index in 0..<2200 { _ = L10n.format("opaque current status %@", String(index)) }
        L10n.clearDisplayCache()
        L10n.setLanguage(.english, defaults: defaults)
        XCTAssertEqual(model.message, "Downloading update: 配置中心.zip")
        XCTAssertEqual(updates.status, "Waiting to check for updates")
        XCTAssertEqual(connection.localizedText, "Enter an FTP hostname or IP address without whitespace.")
        XCTAssertEqual(autosave.localizedStatusText, "Not saved: The port must be from 1 to 65535")
        XCTAssertEqual(model.transferLogs, history, "Stored logs retain the language they were written in")
        XCTAssertEqual(model.settingsError, "更新", "Unknown String input must not collide with another generated label")
        XCTAssertEqual(model.preferences, preferences)
        XCTAssertEqual(autosave.portText, "invalid", "Changing language must preserve an unsaved draft")
    }
}
