import AppKit
import SwiftUI

/// 只保存配置页面所属主窗口的弱引用；用于结束编辑和关窗前提交，不创建额外窗口。
@MainActor final class SettingsWindowAccess: ObservableObject {
    weak var window: NSWindow?
    var willClose: (() -> Void)?
    func flushBeforeClose() {
        window?.makeFirstResponder(nil)
        willClose?()
    }
}

struct SettingsWindowReader: NSViewRepresentable {
    let access: SettingsWindowAccess
    func makeNSView(context: Context) -> WindowReaderView {
        WindowReaderView(access: access)
    }
    func updateNSView(_ nsView: WindowReaderView, context: Context) { nsView.access = access }

    final class WindowReaderView: NSView {
        weak var access: SettingsWindowAccess?
        private var closeObserver: NSObjectProtocol?
        init(access: SettingsWindowAccess) {
            self.access = access
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
            closeObserver = nil
            access?.window = window
            if let window {
                closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                    object: window, queue: .main) { [weak access] _ in
                        MainActor.assumeIsolated { access?.flushBeforeClose() }
                    }
            }
        }
        deinit { if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) } }
    }
}
