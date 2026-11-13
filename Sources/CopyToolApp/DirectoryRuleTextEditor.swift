import CopyToolCore
import AppKit
import SwiftUI

/// 规则文本需要原样保存通配符，并在横向滚动中显示长路径。
struct DirectoryRuleTextEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }
    func makeNSView(context: Context) -> NSScrollView { makeScrollView(coordinator: context.coordinator) }
    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let editor = scrollView.documentView as? RuleTextView else { return }
        context.coordinator.update(binding: $text, value: text, editor: editor)
    }
    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        guard let editor = scrollView.documentView as? RuleTextView else { return }
        editor.delegate = nil
        editor.didEndMarkedText = nil
    }

    // 同时用于原生控件输入测试，不依赖 SwiftUI Context 或窗口呈现。
    func makeScrollView(coordinator: Coordinator) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        let editor = RuleTextView(frame: .zero)
        editor.isEditable = true
        editor.isSelectable = true
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.usesFontPanel = false
        editor.usesRuler = false
        editor.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        editor.textColor = .textColor
        editor.backgroundColor = .textBackgroundColor
        editor.textContainerInset = NSSize(width: 8, height: 8)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = true
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = false
        editor.textContainer?.heightTracksTextView = false
        editor.textContainer?.containerSize = editor.maxSize
        editor.textContainer?.lineFragmentPadding = 0
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.isAutomaticDataDetectionEnabled = false
        editor.isAutomaticTextCompletionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isGrammarCheckingEnabled = false
        editor.smartInsertDeleteEnabled = false
        editor.setAccessibilityIdentifier("directory-exclusion-editor-text")
        editor.setAccessibilityLabel(L10n.text("目录排除规则文本，每行一条"))
        editor.string = text
        editor.delegate = coordinator
        editor.didEndMarkedText = { [weak coordinator, weak editor] in
            guard let editor else { return }
            coordinator?.compositionEnded(in: editor)
        }
        scrollView.documentView = editor
        return scrollView
    }

    @MainActor final class RuleTextView: NSTextView {
        var didEndMarkedText: (() -> Void)?
        override func unmarkText() {
            super.unmarkText()
            didEndMarkedText?()
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        private var text: Binding<String>
        private var lastModelValue: String
        private var deferredExternalValue: String?
        private var applyingExternalValue = false

        init(text: Binding<String>) { self.text = text; lastModelValue = text.wrappedValue }

        func update(binding: Binding<String>, value: String, editor: NSTextView) {
            text = binding
            // SwiftUI 的无关刷新不能把尚在输入法组合中的原生内容恢复成旧值。
            guard value != lastModelValue else { return }
            lastModelValue = value
            if editor.hasMarkedText() { deferredExternalValue = value; return }
            deferredExternalValue = nil
            apply(value, to: editor)
        }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView, !applyingExternalValue,
                  !editor.hasMarkedText() else { return }
            compositionEnded(in: editor)
        }

        func compositionEnded(in editor: NSTextView) {
            guard !applyingExternalValue, !editor.hasMarkedText() else { return }
            if let external = deferredExternalValue {
                // 外部的清空／替换仍是最终值，只把应用时机推迟到输入法组合完成。
                deferredExternalValue = nil
                apply(external, to: editor)
                return
            }
            lastModelValue = editor.string
            if text.wrappedValue != editor.string { text.wrappedValue = editor.string }
        }

        private func apply(_ value: String, to editor: NSTextView) {
            guard value != editor.string else { return }
            let selections = editor.selectedRanges.map(\.rangeValue)
            applyingExternalValue = true
            defer { applyingExternalValue = false }
            editor.string = value
            editor.setSelectedRanges(selections.map { NSValue(range: Self.clamp($0, to: value)) },
                                     affinity: .downstream, stillSelecting: false)
        }

        private static func clamp(_ range: NSRange, to value: String) -> NSRange {
            let string = value as NSString
            let length = string.length
            let start = range.location == NSNotFound ? length : min(range.location, length)
            let count = min(range.length, length - start)
            if count > 0 { return string.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: count)) }
            if start == length { return NSRange(location: length, length: 0) }
            return NSRange(location: string.rangeOfComposedCharacterSequence(at: start).location, length: 0)
        }
    }
}
