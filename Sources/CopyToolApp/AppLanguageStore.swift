import Foundation
import Combine
import CopyToolCore

/// 只刷新文案与区域格式，不替换视图、草稿或任何正在执行的服务。
@MainActor final class AppLanguageStore: ObservableObject {
    static let shared = AppLanguageStore()
    @Published private(set) var language: AppLanguage
    private let defaults: UserDefaults
    private var observer: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        language = L10n.language
        observer = NotificationCenter.default.addObserver(forName: L10n.languageDidChange,
            object: nil, queue: nil) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
    }

    func select(_ selected: AppLanguage) {
        L10n.setLanguage(selected, defaults: defaults)
        refresh()
    }

    private func refresh() {
        let selected = L10n.language
        if language != selected { language = selected }
        NativeMenuLocalizer.refresh()
        // SwiftUI 的 commands 随后也会更新，在下一次主循环补齐系统菜单标题。
        DispatchQueue.main.async { NativeMenuLocalizer.refresh() }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
}
