import AppKit
import Sparkle

/// Only packaged builds with an explicit feed and signing key start network checks.
@MainActor final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    private var controller: SPUStandardUpdaterController?
    @Published private(set) var canCheck = true
    var isTransferActive: () -> Bool = { false }
    override init() {
        super.init()
        guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              !feed.isEmpty,
              let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              !key.isEmpty else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
    }
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard isTransferActive() else { return false }
        Task { @MainActor in
            while isTransferActive() { try? await Task.sleep(nanoseconds: 1_000_000_000) }
            installHandler()
        }
        return true
    }
    func check() {
        guard let controller else {
            let alert = NSAlert()
            alert.messageText = "此构建尚未配置自动更新"
            alert.informativeText = "请从项目 Release 下载新版本，或联系维护者配置更新源和签名。"
            alert.runModal()
            return
        }
        guard controller.updater.canCheckForUpdates else { return }
        controller.checkForUpdates(nil)
    }
}
