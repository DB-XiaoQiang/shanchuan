import XCTest
import AppKit
import CopyToolCore
@testable import CopyToolApp

@MainActor final class AppLanguageStoreTests: XCTestCase {
    func testLiveSelectionPersistsWithoutFlushingOrReplacingSettingsDraft() throws {
        let name = "Shanchuan.LiveLanguageTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let previous = L10n.language
        defer {
            L10n.setLanguage(previous, defaults: defaults)
            defaults.removePersistentDomain(forName: name)
        }
        L10n.setLanguage(.simplifiedChinese, defaults: defaults)
        let language = AppLanguageStore(defaults: defaults)
        let settings = SettingsAutosaveStore()
        var saves = 0
        settings.connect(current: { (AppPreferences(), "synthetic-password") }, save: { _, _ in saves += 1; return nil })
        settings.portText = "not-a-port"
        settings.draft.directoryExclusionRules = "报告/\n*.log"
        let identity = ObjectIdentifier(settings)

        language.select(.english)
        XCTAssertEqual(language.language, .english)
        XCTAssertEqual(L10n.text("配置中心"), "Settings")
        XCTAssertEqual(defaults.string(forKey: AppLanguage.preferenceKey), "en")
        XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["en"])
        language.select(.simplifiedChinese)
        XCTAssertEqual(language.language, .simplifiedChinese)
        XCTAssertEqual(L10n.text("配置中心"), "配置中心")
        XCTAssertEqual(ObjectIdentifier(settings), identity)
        XCTAssertEqual(settings.portText, "not-a-port")
        XCTAssertEqual(settings.draft.directoryExclusionRules, "报告/\n*.log")
        XCTAssertEqual(settings.secret, "synthetic-password")
        XCTAssertEqual(saves, 0)
    }

    func testNativeMenuChangesTitlesAndKeepsActionsShortcutsAndUserContent() throws {
        let name = "Shanchuan.NativeMenuTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let previous = L10n.language
        defer {
            L10n.setLanguage(previous, defaults: defaults)
            defaults.removePersistentDomain(forName: name)
        }
        let menu = NSMenu()
        let appItem = NSMenuItem(title: "闪传", action: nil, keyEquivalent: "")
        appItem.submenu = NSMenu()
        menu.addItem(appItem)
        let edit = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        edit.submenu = submenu
        menu.addItem(edit)
        let copy = NSMenuItem(title: "复制", action: NSSelectorFromString("copy:"), keyEquivalent: "c")
        copy.tag = 42
        submenu.addItem(copy)
        let userItem = NSMenuItem(title: "报告中文.txt", action: nil, keyEquivalent: "")
        submenu.addItem(userItem)

        L10n.setLanguage(.english, defaults: defaults)
        NativeMenuLocalizer.refresh(menu: menu)
        XCTAssertEqual(edit.title, "Edit")
        XCTAssertEqual(copy.title, "Copy")
        XCTAssertEqual(copy.action, NSSelectorFromString("copy:"))
        XCTAssertEqual(copy.keyEquivalent, "c")
        XCTAssertEqual(copy.tag, 42)
        XCTAssertEqual(userItem.title, "报告中文.txt")
        L10n.setLanguage(.simplifiedChinese, defaults: defaults)
        NativeMenuLocalizer.refresh(menu: menu)
        XCTAssertEqual(edit.title, "编辑")
        XCTAssertEqual(copy.title, "复制")
        XCTAssertEqual(userItem.title, "报告中文.txt")
    }
}
