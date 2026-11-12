import SwiftUI
import AppKit

@main struct CopyToolApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()
    @StateObject private var updater = AppUpdater()
    @StateObject private var updates = UpdateCoordinator()
    @StateObject private var navigation = AppNavigation()
    @StateObject private var settings = SettingsPageSession()
    var body: some Scene {
        Window("闪传", id: "main") {
            RootView(model: model, updates: updates, navigation: navigation, settings: settings).frame(minWidth: 820, minHeight: 560)
                .onAppear {
                    delegate.connectTransferProgress(model)
                    delegate.navigation = navigation
                    settings.connect(model: model)
                    navigation.prepareToLeaveSettings = { [weak pageSession = settings] in pageSession?.prepareToLeave() ?? true }
                    updates.businessIsBusy = { model.transferSnapshot.isActive || model.queued > 0 }
                    updates.ftpSettings = {
                        guard model.preferences.validationError == nil else { return nil }
                        return .init(host: model.preferences.host, port: model.preferences.port,
                            username: model.preferences.username, password: model.password, directory: model.preferences.directory)
                    }
                    updates.install = { updater.install(version: $0) }
                    updates.writeLog = { text, error in model.log(text, level: error ? .warning : .info) }
                    updater.isTransferActive = { model.transferSnapshot.isActive || model.queued > 0 || updates.isRelaying }
                    updater.setInstallationCommitting = { model.updateInstallationIsCommitting = $0 }
                    updater.cycleFinished = { updates.installationCycleFinished(error: $0) }
                    updater.report = { model.log($0, level: .warning) }
                    updates.start()
                }
        }.defaultSize(width: 1000, height: 720)
        .commands {
            AppNavigationCommands(navigation: navigation)
            UpdateCommands(updates: updates)
            CommandGroup(after: .pasteboard) {
                Button("添加文件…") { model.chooseFiles() }.keyboardShortcut("o")
                Button("恢复选中记录") { if let item = model.selectedEntry { model.restore(item) } }.keyboardShortcut("r")
            }
        }
        MenuBarExtra {
            MenuContents(model: model, navigation: navigation)
        } label: {
            if model.transferSnapshot.isActive {
                Label(model.transferMenuTitle, systemImage: "arrow.up.circle.fill")
            } else { Image(systemName: "bolt.fill").accessibilityLabel("闪传") }
        }
    }
}
struct UpdateCommands: Commands {
    @ObservedObject var updates: UpdateCoordinator
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("检查更新…") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
                updates.check()
            }.disabled(!updates.canCheck)
        }
    }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var transferPresenter: TransferProgressWindowController?
    private weak var model: AppModel?
    weak var navigation: AppNavigation?
    func connectTransferProgress(_ model: AppModel) {
        guard transferPresenter == nil else { return }
        self.model = model
        let presenter = TransferProgressWindowController(model: model)
        transferPresenter = presenter
        model.previewTransferProgress = { [weak presenter] in presenter?.preview() }
        model.showTransferProgressCard = { [weak presenter] in presenter?.showCurrent() }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard navigation?.prepareToLeaveCurrentPage() ?? true else {
            navigation?.showMainWindow?()
            sender.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
            sender.activate(ignoringOtherApps: true)
            return .terminateCancel
        }
        return .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) {
        model?.flushSettings?()
        transferPresenter?.stop()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        FailureNotifications.shared.configure()
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
    @ObservedObject var navigation: AppNavigation
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("显示窗口") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Button("配置中心") {
            navigation.select(.settings)
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
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
