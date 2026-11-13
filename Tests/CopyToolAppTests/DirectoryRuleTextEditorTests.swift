import AppKit
import SwiftUI
import XCTest
@testable import CopyToolApp

@MainActor private final class DirectoryRuleTextState {
    var text: String
    var writes = 0
    init(_ text: String) { self.text = text }
    var binding: Binding<String> {
        Binding(get: { self.text }, set: { self.text = $0; self.writes += 1 })
    }
}

final class DirectoryRuleTextEditorTests: XCTestCase {
    @MainActor
    func testNativeInputPreservesGlobPunctuationAndNotifiesBinding() throws {
        let state = DirectoryRuleTextState("")
        let bridge = DirectoryRuleTextEditor(text: state.binding)
        let coordinator = bridge.makeCoordinator()
        let scroll = bridge.makeScrollView(coordinator: coordinator)
        let editor = try XCTUnwrap(scroll.documentView as? NSTextView)
        let literal = "**/中文路径/\"quoted\"/file--name?.log\n*.txt\n# don't replace 'quotes'..."
        editor.insertText(literal, replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(editor.string, literal)
        XCTAssertEqual(state.text, literal)
        XCTAssertGreaterThan(state.writes, 0)
        XCTAssertFalse(editor.isRichText)
        XCTAssertFalse(editor.isAutomaticQuoteSubstitutionEnabled)
        XCTAssertFalse(editor.isAutomaticDashSubstitutionEnabled)
        XCTAssertFalse(editor.isAutomaticTextReplacementEnabled)
        XCTAssertFalse(editor.isAutomaticSpellingCorrectionEnabled)
        XCTAssertEqual(editor.accessibilityIdentifier(), "directory-exclusion-editor-text")
    }

    @MainActor
    func testExternalChangesPreserveUTF16SelectionAndClampToWholeCharacters() throws {
        let state = DirectoryRuleTextState("a😀bc")
        let bridge = DirectoryRuleTextEditor(text: state.binding)
        let coordinator = bridge.makeCoordinator()
        let scroll = bridge.makeScrollView(coordinator: coordinator)
        let editor = try XCTUnwrap(scroll.documentView as? NSTextView)
        editor.setSelectedRange(NSRange(location: 3, length: 1))
        state.text += "/**"
        coordinator.update(binding: state.binding, value: state.text, editor: editor)
        XCTAssertEqual(editor.string, "a😀bc/**")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 3, length: 1))
        XCTAssertEqual(state.writes, 0, "外部更新不应递归回写同一 Binding")

        editor.setSelectedRange(NSRange(location: 3, length: 0))
        state.text = "👩‍💻x"
        coordinator.update(binding: state.binding, value: state.text, editor: editor)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 0), "光标不能落在组合 Emoji 的 UTF-16 中间")
        state.text = "中"
        coordinator.update(binding: state.binding, value: state.text, editor: editor)
        editor.setSelectedRange(NSRange(location: 1, length: 0))
        state.text = ""
        coordinator.update(binding: state.binding, value: state.text, editor: editor)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 0))
    }

    @MainActor
    func testSwiftUIEchoDoesNotResetNativeCaret() throws {
        let state = DirectoryRuleTextState("abc")
        let bridge = DirectoryRuleTextEditor(text: state.binding)
        let coordinator = bridge.makeCoordinator()
        let scroll = bridge.makeScrollView(coordinator: coordinator)
        let editor = try XCTUnwrap(scroll.documentView as? NSTextView)
        editor.setSelectedRange(NSRange(location: 1, length: 0))
        editor.insertText("?", replacementRange: NSRange(location: 1, length: 0))
        let caret = editor.selectedRange()
        coordinator.update(binding: state.binding, value: state.text, editor: editor)
        XCTAssertEqual(state.text, "a?bc")
        XCTAssertEqual(editor.selectedRange(), caret)
    }

    @MainActor
    func testExternalReplacementWaitsForMarkedTextToFinish() throws {
        let state = DirectoryRuleTextState("before")
        let bridge = DirectoryRuleTextEditor(text: state.binding)
        let coordinator = bridge.makeCoordinator()
        let scroll = bridge.makeScrollView(coordinator: coordinator)
        let editor = try XCTUnwrap(scroll.documentView as? DirectoryRuleTextEditor.RuleTextView)
        editor.setSelectedRange(NSRange(location: 6, length: 0))
        editor.setMarkedText("拼音", selectedRange: NSRange(location: 2, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        let composition = editor.string
        // 无关 SwiftUI 重绘不能终止输入法组合或恢复旧的 before。
        coordinator.update(binding: state.binding, value: state.text, editor: editor)
        XCTAssertEqual(editor.string, composition)
        XCTAssertTrue(editor.hasMarkedText())
        state.text = "**/external/?"
        coordinator.update(binding: state.binding, value: state.text, editor: editor)
        XCTAssertEqual(editor.string, composition)
        XCTAssertTrue(editor.hasMarkedText())
        editor.unmarkText()
        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertEqual(editor.string, "**/external/?")
        XCTAssertEqual(state.text, "**/external/?")
    }

    @MainActor
    func testLongPathRemainsOneLiteralLineInNarrowViewport() throws {
        let literal = String(repeating: "very-long-directory/", count: 80) + "**/file?.log"
        let state = DirectoryRuleTextState(literal)
        let bridge = DirectoryRuleTextEditor(text: state.binding)
        let coordinator = bridge.makeCoordinator()
        let scroll = bridge.makeScrollView(coordinator: coordinator)
        scroll.frame = NSRect(x: 0, y: 0, width: 180, height: 120)
        let editor = try XCTUnwrap(scroll.documentView as? NSTextView)
        let container = try XCTUnwrap(editor.textContainer)
        let layout = try XCTUnwrap(editor.layoutManager)
        scroll.layoutSubtreeIfNeeded()
        layout.ensureLayout(for: container)
        var lines = 0
        layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { _, _, _, _, _ in lines += 1 }
        XCTAssertEqual(editor.string, literal)
        XCTAssertEqual(state.text, literal)
        XCTAssertEqual(lines, 1, "长路径应该横向滚动，不应按视口宽度折成多行")
        XCTAssertTrue(scroll.hasHorizontalScroller)
        XCTAssertTrue(scroll.hasVerticalScroller)
        XCTAssertGreaterThan(editor.frame.width, scroll.contentSize.width,
                             "原生文档实际宽度必须容纳长路径，才能产生可滚动范围")
        editor.scrollRangeToVisible(NSRange(location: (literal as NSString).length, length: 0))
        XCTAssertGreaterThan(scroll.documentVisibleRect.minX, 0,
                             "应能把末尾规则滚动到视口，而不只是显示水平滚动条")
        let lastCharacter = NSRange(location: (literal as NSString).length - 1, length: 1)
        let lastGlyph = layout.glyphRange(forCharacterRange: lastCharacter, actualCharacterRange: nil)
        let lastGlyphRect = layout.boundingRect(forGlyphRange: lastGlyph, in: container)
            .offsetBy(dx: editor.textContainerOrigin.x, dy: editor.textContainerOrigin.y)
        XCTAssertTrue(scroll.documentVisibleRect.intersects(lastGlyphRect), "横向滚动后应能看到路径末尾")
    }
}
