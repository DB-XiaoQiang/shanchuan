import AppKit
import SwiftUI

/// 主窗口的共享页面选择，菜单、侧栏和通知使用同一条导航路径。
@MainActor final class AppNavigation: ObservableObject {
    enum Page: String, CaseIterable, Hashable {
        case history, logs, settings, about
        var title: String {
            switch self {
            case .history: return "剪贴板记录"
            case .logs: return "传输日志"
            case .settings: return "配置中心"
            case .about: return "使用说明"
            }
        }
    }
    @Published private(set) var page: Page = .history
    var prepareToLeaveSettings: (() -> Bool)?
    var showMainWindow: (() -> Void)?
    var acceptsFileDrop: Bool { page == .history }

    @discardableResult func select(_ destination: Page) -> Bool {
        guard destination != page else { return true }
        guard prepareToLeaveCurrentPage() else { return false }
        page = destination
        return true
    }
    func prepareToLeaveCurrentPage() -> Bool {
        page != .settings || (prepareToLeaveSettings?() ?? true)
    }
}

struct AppNavigationCommands: Commands {
    @ObservedObject var navigation: AppNavigation
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("配置中心…") {
                navigation.select(.settings)
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }.keyboardShortcut(",", modifiers: .command)
        }
    }
}
