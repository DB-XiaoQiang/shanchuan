import AppKit
import Sparkle
import CopyToolCore

/// Sparkle is created only after explicit approval, never by the daily checker.
@MainActor final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    private var controller: SPUStandardUpdaterController?
    private var approvedVersion: String?
    var isTransferActive: () -> Bool = { false }
    var setInstallationCommitting: (Bool) -> Void = { _ in }
    var cycleFinished: (String?) -> Void = { _ in }
    var report: (String) -> Void = { _ in }
    override init() {
        super.init()
        // Migrate previous Sparkle preferences before any updater is created.
        for key in ["SUEnableAutomaticChecks", "SUAutomaticallyUpdate", "SUAutomaticallyDownloadUpdates"] {
            UserDefaults.standard.set(false, forKey: key)
        }
    }
    func install(version: String) -> Bool {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String, !key.isEmpty else {
            report("此构建尚未配置 Sparkle 验签公钥，请手动安装正式 DMG。")
            return false
        }
        if let controller, !controller.updater.canCheckForUpdates { report("更新安装流程正在进行。"); return false }
        approvedVersion = version
        let updaterController = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        updaterController.updater.automaticallyChecksForUpdates = false
        updaterController.updater.automaticallyDownloadsUpdates = false
        updaterController.updater.clearFeedURLFromUserDefaults()
        controller = updaterController
        updaterController.startUpdater()
        updaterController.checkForUpdates(nil)
        return true
    }
    func feedURLString(for updater: SPUUpdater) -> String? {
        guard let approvedVersion else { return nil }
        return UpdateCoordinator.repository + "/releases/download/v" + approvedVersion + "/appcast.xml"
    }
    static func validateTarget(actual: String, approved: String?) throws {
        guard let approved, actual == approved else { throw UpdateFailure.invalid("更新源返回的版本与已确认版本不一致。") }
    }
    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate updateItem: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        try Self.validateTarget(actual: updateItem.displayVersionString, approved: approvedVersion)
    }
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard isTransferActive() else { setInstallationCommitting(true); return false }
        Task { @MainActor in
            while isTransferActive() { try? await Task.sleep(nanoseconds: 500_000_000) }
            setInstallationCommitting(true)
            installHandler()
        }
        return true
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        setInstallationCommitting(false)
        cycleFinished(error.localizedDescription)
    }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        setInstallationCommitting(false)
        cycleFinished(error?.localizedDescription)
    }
}
