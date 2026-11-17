import CoreGraphics
import XCTest
@testable import CopyToolApp

final class GlobalShortcutReleaseTests: XCTestCase {
    @MainActor func testMainKeyMustBeReleasedEvenAfterAllModifiersAreUp() {
        XCTAssertFalse(GlobalCopyPasteShortcuts.shortcutKeysReleased(mainKeyDown: true, flags: []),
                       "Carbon may report a hotkey release when a modifier is released before its main key")
        XCTAssertTrue(GlobalCopyPasteShortcuts.shortcutKeysReleased(mainKeyDown: false, flags: []))
    }

    @MainActor func testEachCommandModifierAndFunctionKeyBlocksDispatch() {
        let modifiers: [CGEventFlags] = [.maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn]
        for modifier in modifiers {
            XCTAssertFalse(GlobalCopyPasteShortcuts.shortcutKeysReleased(mainKeyDown: false, flags: modifier),
                           "A held modifier must not alter the synthetic Command+C/V event sequence: \(modifier)")
            XCTAssertFalse(GlobalCopyPasteShortcuts.shortcutKeysReleased(mainKeyDown: true, flags: modifier))
        }
    }

    @MainActor func testPartialReleaseOfConfiguredChordRemainsBlocked() {
        let states: [CGEventFlags] = [
            [.maskControl, .maskAlternate], .maskControl, .maskAlternate,
            [.maskCommand, .maskShift, .maskSecondaryFn]
        ]
        for flags in states {
            XCTAssertFalse(GlobalCopyPasteShortcuts.shortcutKeysReleased(mainKeyDown: false, flags: flags))
        }
        XCTAssertFalse(GlobalCopyPasteShortcuts.shortcutKeysReleased(mainKeyDown: true, flags: []))
        XCTAssertTrue(GlobalCopyPasteShortcuts.shortcutKeysReleased(mainKeyDown: false, flags: []))
    }

    @MainActor func testCapsLockAndNumericPadFlagsDoNotBlockAReleasedShortcut() {
        let states: [CGEventFlags] = [.maskAlphaShift, .maskNumericPad, [.maskAlphaShift, .maskNumericPad]]
        for flags in states {
            XCTAssertTrue(GlobalCopyPasteShortcuts.shortcutKeysReleased(mainKeyDown: false, flags: flags))
            XCTAssertFalse(GlobalCopyPasteShortcuts.shortcutKeysReleased(mainKeyDown: true, flags: flags))
        }
    }

    @MainActor func testIgnoredFlagsCannotHideAHeldModifier() {
        let flags: CGEventFlags = [.maskAlphaShift, .maskNumericPad, .maskControl]
        XCTAssertFalse(GlobalCopyPasteShortcuts.shortcutKeysReleased(mainKeyDown: false, flags: flags))
    }
}
