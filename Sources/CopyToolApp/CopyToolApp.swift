import SwiftUI
import AppKit

@main struct CopyToolApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        Window("闪传", id: "main") {
            RootView(model: model).frame(minWidth: 820, minHeight: 560)
                .onAppear { delegate.connectTransferProgress(model) }
        }.defaultSize(width: 1000, height: 720)
        .commands {
            CommandGroup(after: .pasteboard) {
                Button("添加文件…") { model.chooseFiles() }.keyboardShortcut("o")
                Button("恢复选中记录") { if let item = model.selectedEntry { model.restore(item) } }.keyboardShortcut("r")
            }
        }
        Settings { SettingsView(model: model).frame(width: 550).padding(24) }
        MenuBarExtra {
            MenuContents(model: model)
        } label: {
            if model.transferSnapshot.isActive {
                Label(model.transferMenuTitle, systemImage: "arrow.up.circle.fill")
            } else { Image(systemName: "bolt.fill").accessibilityLabel("闪传") }
        }
    }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var transferPresenter: TransferProgressWindowController?
    private weak var model: AppModel?
    func connectTransferProgress(_ model: AppModel) {
        guard transferPresenter == nil else { return }
        self.model = model
        let presenter = TransferProgressWindowController(model: model)
        transferPresenter = presenter
        model.previewTransferProgress = { [weak presenter] in presenter?.preview() }
        model.showTransferProgressCard = { [weak presenter] in presenter?.showCurrent() }
    }
    func applicationWillTerminate(_ notification: Notification) {
        model?.flushSettings?()
        transferPresenter?.stop()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { sender.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil) }; return true
    }
}
struct MenuContents: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("显示窗口") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Button("复制并发送前台内容") { model.copyInFrontmostApplication() }
        Button("粘贴到前台应用") { model.pasteInFrontmostApplication() }
        Divider()
        if model.transferSnapshot.isActive {
            Text(model.privacy ? "文件传输" : model.transferSnapshot.title).lineLimit(1)
            Text(model.transferMenuTitle)
        }
        Button("显示传输进度") { model.showTransferProgressCard?() }
            .disabled(!model.transferSnapshot.isActive && !model.transferSnapshot.isTerminal)
        Divider()
        Text("普通复制不记录、不上传")
        Divider()
        Button("添加文件…") { model.chooseFiles() }
        Button("取消所有传输") { model.cancelAll() }.disabled(model.activeTransfer.isEmpty && model.queued == 0)
        Divider()
        Button("退出") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
