import Foundation
import Combine
import CopyToolCore

/// 页面离开或主窗口关闭后仍保留未保存草稿，重新进入时不会覆盖用户输入。
@MainActor final class SettingsPageSession: ObservableObject {
    let autosave = SettingsAutosaveStore()
    let connectionTest = FTPConnectionTestStore()
    let windowAccess = SettingsWindowAccess()
    private var connected = false

    func connect(model: AppModel) {
        guard !connected else { return }
        connected = true
        autosave.connect(current: { [weak model] in
            (model?.preferences ?? AppPreferences(), model?.password ?? "")
        }, save: { [weak model] values, password in
            guard let model else { return L10n.text("设置尚未就绪") }
            guard model.saveSettings(preferences: values, password: password) else { return model.settingsError }
            return nil
        }, failureOrigin: { [weak model] in model?.settingsErrorSnapshot })
        windowAccess.willClose = { [weak self] in self?.flushAndCancelTest() }
        model.flushSettings = { [weak self] in self?.windowAccess.flushBeforeClose() }
    }

    func prepareToLeave() -> Bool {
        windowAccess.flushBeforeClose()
        if case .failed = autosave.status { return false }
        return true
    }

    private func flushAndCancelTest() {
        autosave.flush()
        connectionTest.cancel()
    }
}
