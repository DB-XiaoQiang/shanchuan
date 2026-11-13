import AppKit
import SwiftUI
import CopyToolCore

struct ShortcutSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var draft = CopyPasteShortcuts()
    @State private var autosaveStatus = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(L10n.text("启用复制发送 / 粘贴快捷键"), isOn: Binding(
                get: { draft.enabled },
                set: { enabled in
                    guard draft.enabled != enabled else { return }
                    if !enabled {
                        // 关闭服务不能被尚未保存的非法录制结果阻止。
                        draft = model.preferences.shortcuts
                        draft.enabled = false
                        saveDraft(validateBindings: false)
                        return
                    }
                    draft.enabled = enabled
                    saveDraft()
                }))
            ShortcutRecorderRow(title: L10n.text("复制并发送到内网"), binding: shortcutBinding(\.copy), recordingChanged: model.setShortcutRecording)
            ShortcutRecorderRow(title: L10n.text("粘贴到当前应用"), binding: shortcutBinding(\.paste), recordingChanged: model.setShortcutRecording)
            Text(L10n.text("复制发送快捷键先复制当前应用所选内容，再发送到已配置的内网 FTP；粘贴快捷键只在当前应用粘贴。"))
                .font(.caption).foregroundStyle(.secondary)
            Text(L10n.text("Command+C 只作普通复制，不记录到本应用，也不会上传。“开启历史记录”仅控制明确发送的内容是否保留记录。点击组合键可重新录制，修改后自动保存，按 Esc 取消；关闭主窗口后仍生效。"))
                .font(.caption).foregroundStyle(.secondary)
            Text(model.shortcutPermissionGranted ? L10n.text("辅助功能权限已允许") : L10n.text("全局操作需要在 macOS 辅助功能中允许“闪传”。"))
                .font(.caption).foregroundStyle(model.shortcutPermissionGranted ? Color.secondary : Color.orange)
            HStack {
                if !model.shortcutPermissionGranted {
                    Button(L10n.text("打开辅助功能设置")) { model.openShortcutAccessibilitySettings() }
                }
                Button(L10n.text("恢复默认组合")) {
                    var defaults = draft
                    defaults.copy = .init(keyCode: 8, modifiers: 6)
                    defaults.paste = .init(keyCode: 9, modifiers: 6)
                    draft = defaults
                    saveDraft()
                }
                Spacer()
            }
            if let error = validationError { Text(L10n.text("未保存：") + error).font(.caption).foregroundStyle(.red) }
            else if !model.shortcutSettingsError.isEmpty { Text(L10n.text("未保存：") + model.shortcutSettingsError).font(.caption).foregroundStyle(.red) }
            else if !autosaveStatus.isEmpty { Text(autosaveStatus).font(.caption).foregroundStyle(.secondary) }
            if !model.shortcutStatus.isEmpty { Text(model.shortcutStatus).font(.caption).foregroundStyle(.secondary) }
        }
        .onAppear { draft = model.preferences.shortcuts; autosaveStatus = ""; model.refreshShortcutPermission() }
        .onChange(of: model.preferences.shortcuts) { draft = $0 }
        .onDisappear { model.setShortcutRecording(false) }
    }

    private var validationError: String? {
        // 录制时即校验组合；停用状态也不把非法按键写入配置。
        var candidate = draft
        candidate.enabled = true
        return candidate.validationError
    }

    private func shortcutBinding(_ keyPath: WritableKeyPath<CopyPasteShortcuts, ShortcutBinding>) -> Binding<ShortcutBinding> {
        Binding(get: { draft[keyPath: keyPath] }, set: { binding in
            guard draft[keyPath: keyPath] != binding else { return }
            draft[keyPath: keyPath] = binding
            saveDraft()
        })
    }

    private func saveDraft(validateBindings: Bool = true) {
        autosaveStatus = ""
        guard !validateBindings || validationError == nil else { return }
        if draft == model.preferences.shortcuts || model.saveShortcutConfiguration(draft) {
            autosaveStatus = L10n.text("快捷键已保存")
        }
    }
}

private struct ShortcutRecorderRow: View {
    let title: String
    @Binding var binding: ShortcutBinding
    let recordingChanged: (Bool) -> Void
    var body: some View {
        HStack {
            Text(title).frame(width: 190, alignment: .leading)
            ShortcutRecorder(binding: $binding, title: title, recordingChanged: recordingChanged)
                .frame(width: 210, height: 28)
            Spacer()
        }
    }
}

private struct ShortcutRecorder: NSViewRepresentable {
    @Binding var binding: ShortcutBinding
    let title: String
    let recordingChanged: (Bool) -> Void
    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        updateNSView(button, context: context)
        return button
    }
    func updateNSView(_ button: RecorderButton, context: Context) {
        button.displayTitle = binding.displayName
        button.setAccessibilityLabel(title + L10n.text("快捷键"))
        button.setAccessibilityHelp(L10n.text("点击后按新的组合键，按 Escape 取消录制"))
        button.onChange = { binding = $0 }
        button.onRecordingChanged = recordingChanged
        if !button.recording { button.title = button.displayTitle }
    }
    static func dismantleNSView(_ button: RecorderButton, coordinator: ()) { button.endRecording() }
}

private final class RecorderButton: NSButton {
    var displayTitle = ""
    var onChange: ((ShortcutBinding) -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?
    private(set) var recording = false
    private var monitor: Any?
    private var resignObserver: Any?
    override var acceptsFirstResponder: Bool { true }
    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded; target = self; action = #selector(beginRecording)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func beginRecording() {
        guard !recording else { endRecording(); return }
        window?.makeFirstResponder(self)
        recording = true; title = L10n.text("请按组合键…（Esc 取消）")
        onRecordingChanged?(true)
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            self?.endRecording()
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.recording, event.windowNumber == self.window?.windowNumber else { return event }
            if event.keyCode == 53 { self.endRecording(); return nil }
            if event.isARepeat { return nil }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            var modifiers: UInt32 = 0
            if flags.contains(.command) { modifiers |= 1 }
            if flags.contains(.option) { modifiers |= 2 }
            if flags.contains(.control) { modifiers |= 4 }
            if flags.contains(.shift) { modifiers |= 8 }
            let binding = ShortcutBinding(keyCode: UInt32(event.keyCode), modifiers: modifiers)
            self.displayTitle = binding.displayName
            // 先恢复服务，保存时才能检查新组合是否被系统或其他应用占用。
            self.endRecording()
            self.onChange?(binding)
            return nil
        }
    }
    func endRecording() {
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver); self.resignObserver = nil }
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        guard recording else { return }
        recording = false; title = displayTitle; onRecordingChanged?(false)
    }
    override func resignFirstResponder() -> Bool { endRecording(); return super.resignFirstResponder() }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { endRecording() }
        super.viewWillMove(toWindow: newWindow)
    }
    deinit {
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}
