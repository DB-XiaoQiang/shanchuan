import XCTest
@testable import CopyToolCore

final class ShortcutPreferencesTests: XCTestCase {
    func testLegacyPreferencesPreserveEveryExistingField() throws {
        let legacyJSON = """
        {
          "host":"192.0.2.18","port":2121,"username":"synthetic-user",
          "directory":"/合成测试/收件箱","ttlDays":14,"syncEnabled":true,
          "historyEnabled":false,"notificationsEnabled":true,"restoreOnResend":true,
          "contactsURL":"https://example.invalid/contacts","textRemoteName":"synthetic.temp",
          "autoDecrypt":false,"decryptPrefix":"/synthetic-decrypt/"
        }
        """
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: Data(legacyJSON.utf8))
        var expected = AppPreferences()
        expected.host = "192.0.2.18"
        expected.port = 2121
        expected.username = "synthetic-user"
        expected.directory = "/合成测试/收件箱"
        expected.ttlDays = 14
        expected.syncEnabled = true
        expected.historyEnabled = false
        expected.notificationsEnabled = true
        expected.restoreOnResend = true
        expected.textRemoteName = "synthetic.temp"
        expected.autoDecrypt = false
        expected.decryptPrefix = "/synthetic-decrypt/"
        XCTAssertEqual(decoded, expected)
        XCTAssertFalse(decoded.shortcuts.enabled)
    }

    func testMissingPreferencesUseDefaults() throws {
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded, AppPreferences())
    }

    func testCustomShortcutsRoundTripWithPreferences() throws {
        var preferences = AppPreferences()
        preferences.host = "192.0.2.19"
        preferences.username = "synthetic-user"
        preferences.shortcuts = CopyPasteShortcuts(
            enabled: true,
            copy: .init(keyCode: 0, modifiers: 7),
            paste: .init(keyCode: 11, modifiers: 10))
        let encoded = try JSONEncoder().encode(preferences)
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: encoded)
        XCTAssertEqual(decoded, preferences)
        XCTAssertNil(decoded.validationError)
    }

    func testDefaultBindingsUseStableModifierBits() {
        var shortcuts = CopyPasteShortcuts()
        XCTAssertFalse(shortcuts.enabled)
        XCTAssertEqual(shortcuts.copy, ShortcutBinding(keyCode: 8, modifiers: 6))
        XCTAssertEqual(shortcuts.paste, ShortcutBinding(keyCode: 9, modifiers: 6))
        XCTAssertEqual(shortcuts.copy.displayName, "⌃⌥C")
        shortcuts.enabled = true
        XCTAssertNil(shortcuts.validationError)
        XCTAssertEqual(ShortcutBinding.commandModifier, 1)
        XCTAssertEqual(ShortcutBinding.optionModifier, 2)
        XCTAssertEqual(ShortcutBinding.controlModifier, 4)
        XCTAssertEqual(ShortcutBinding.shiftModifier, 8)
    }

    func testDuplicateBindingsAreRejected() {
        var shortcuts = CopyPasteShortcuts(enabled: true)
        shortcuts.paste = shortcuts.copy
        XCTAssertEqual(shortcuts.validationError, "复制和粘贴快捷键不能相同")
    }

    func testUnmodifiedAndShiftOnlyKeysAreRejected() {
        for modifiers: UInt32 in [0, 8] {
            var shortcuts = CopyPasteShortcuts(enabled: true)
            shortcuts.copy = .init(keyCode: 8, modifiers: modifiers)
            XCTAssertNotNil(shortcuts.validationError)
        }
    }

    func testUnsupportedKeysAndModifiersAreRejected() {
        var shortcuts = CopyPasteShortcuts(enabled: true)
        shortcuts.copy = .init(keyCode: 55, modifiers: 6) // Command 本身不是按键选择。
        XCTAssertNotNil(shortcuts.validationError)
        shortcuts.copy = .init(keyCode: 8, modifiers: 22)
        XCTAssertNotNil(shortcuts.validationError)
    }

    func testSystemShortcutsAreRejected() {
        let reserved: [ShortcutBinding] = [
            .init(keyCode: 8, modifiers: 1), .init(keyCode: 9, modifiers: 1),
            .init(keyCode: 9, modifiers: 9), .init(keyCode: 12, modifiers: 1),
            .init(keyCode: 12, modifiers: 5), .init(keyCode: 13, modifiers: 1),
            .init(keyCode: 4, modifiers: 1), .init(keyCode: 48, modifiers: 1),
            .init(keyCode: 49, modifiers: 1), .init(keyCode: 53, modifiers: 3),
            .init(keyCode: 20, modifiers: 9)
        ]
        for binding in reserved {
            var shortcuts = CopyPasteShortcuts(enabled: true)
            shortcuts.copy = binding
            XCTAssertNotNil(shortcuts.validationError, binding.displayName)
        }
    }

    func testDisabledBindingsDoNotBlockLegacySettings() {
        var shortcuts = CopyPasteShortcuts()
        shortcuts.copy = .init(keyCode: 999, modifiers: 0)
        shortcuts.paste = shortcuts.copy
        XCTAssertNil(shortcuts.validationError)
    }

    func testCatalogContainsUniqueLettersDigitsAndSpecialKeys() {
        XCTAssertEqual(ShortcutKeyCatalog.keys.count, ShortcutKeyCatalog.allowedKeyCodes.count)
        for letter in "ABCDEFGHIJKLMNOPQRSTUVWXYZ" {
            XCTAssertTrue(ShortcutKeyCatalog.keys.contains { $0.displayName == String(letter) })
        }
        for digit in 0...9 {
            XCTAssertTrue(ShortcutKeyCatalog.keys.contains { $0.displayName == String(digit) })
        }
        XCTAssertEqual(ShortcutKeyCatalog.displayName(for: 49), "空格")
        XCTAssertEqual(ShortcutKeyCatalog.displayName(for: 48), "Tab")
    }
}
