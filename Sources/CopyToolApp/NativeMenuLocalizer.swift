import AppKit
import CopyToolCore

/// SwiftUI 自有命令会重绘；系统菜单由 AppKit 缓存，按公开 action 更新它们的标题。
@MainActor enum NativeMenuLocalizer {
    static func refresh(menu: NSMenu? = nil) {
        guard let menu = menu ?? NSApp?.mainMenu else { return }
        let applicationName = AppRuntimeProfile.current.applicationName
        let topLevel: [(String, String)] = [("编辑", "Edit"), ("显示", "View"), ("窗口", "Window"), ("帮助", "Help")]
        for (index, item) in menu.items.enumerated() {
            if index == 0 {
                item.title = applicationName
                item.submenu?.title = applicationName
            } else if let source = topLevel.first(where: { item.title == $0.0 || item.title == $0.1 })?.0 {
                item.title = L10n.text(source)
                item.submenu?.title = item.title
            }
            if let submenu = item.submenu { refreshActions(submenu, applicationName: applicationName) }
        }
    }

    private static func refreshActions(_ menu: NSMenu, applicationName: String) {
        let actions: [String: String] = [
            "undo:": "撤销", "redo:": "重做", "cut:": "剪切", "copy:": "复制", "paste:": "粘贴",
            "pasteAsPlainText:": "粘贴并匹配样式", "delete:": "删除", "selectAll:": "全选",
            "hideOtherApplications:": "隐藏其他", "unhideAllApplications:": "显示全部",
            "performMiniaturize:": "最小化", "performZoom:": "缩放", "arrangeInFront:": "前置全部窗口"
        ]
        for item in menu.items {
            if let action = item.action {
                switch NSStringFromSelector(action) {
                case "terminate:": item.title = L10n.format("退出%@", applicationName)
                case "hide:": item.title = L10n.format("隐藏%@", applicationName)
                case "orderFrontStandardAboutPanel:": item.title = L10n.format("关于%@", applicationName)
                default:
                    if let source = actions[NSStringFromSelector(action)] { item.title = L10n.text(source) }
                }
            }
            // 最近使用文件等动态子菜单属于用户内容，不能按标题递归翻译。
        }
    }
}
