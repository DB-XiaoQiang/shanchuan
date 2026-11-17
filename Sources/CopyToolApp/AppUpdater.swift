import AppKit
import Sparkle
import CopyToolCore

/// Sparkle is created only after explicit approval, never by the daily checker.
@MainActor final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    private var updater: SPUUpdater?
    private var userDriver: LocalizedUpdateUserDriver?
    private var approvedVersion: String?
    private var installationCycle: UUID?
    private var deferredRelaunch: Task<Void, Never>?
    private let channel: UpdateChannel
    var isTransferActive: () -> Bool = { false }
    var setInstallationCommitting: (Bool) -> Void = { _ in }
    var cycleFinished: (String?) -> Void = { _ in }
    var report: (String) -> Void = { _ in }
    init(channel: UpdateChannel = .production) {
        self.channel = channel
        super.init()
        // Migrate previous Sparkle preferences before any updater is created.
        for key in ["SUEnableAutomaticChecks", "SUAutomaticallyUpdate", "SUAutomaticallyDownloadUpdates"] {
            UserDefaults.standard.set(false, forKey: key)
        }
    }
    func install(version: String) -> Bool {
        if let updater, !updater.canCheckForUpdates { report(L10n.text("更新安装流程正在进行。")); return false }
        revokeCurrentApproval()
        do {
            if let error = channel.configurationError { throw UpdateFailure.invalid(error) }
            try channel.validateManifestVersion(version)
        } catch { report(error.localizedDescription); return false }
        guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String, !key.isEmpty else {
            report(L10n.text("此构建尚未配置 Sparkle 验签公钥，请手动安装正式 DMG。"))
            return false
        }
        userDriver?.dismissUpdateInstallation()
        approvedVersion = version
        installationCycle = UUID()
        let profile = AppRuntimeProfile.current
        let driver = LocalizedUpdateUserDriver(language: L10n.language, applicationName: profile.applicationName,
            applicationNameProvider: { language in L10n.text(profile.isUpdateTest ? "闪传更新测试" : "闪传", language: language) },
            approvedVersion: version)
        let newUpdater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
        newUpdater.automaticallyChecksForUpdates = false
        newUpdater.automaticallyDownloadsUpdates = false
        newUpdater.clearFeedURLFromUserDefaults()
        userDriver = driver; updater = newUpdater
        do { try newUpdater.start() }
        catch {
            revokeCurrentApproval(); userDriver = nil; updater = nil
            report(error.localizedDescription); return false
        }
        newUpdater.checkForUpdates()
        return true
    }
    func feedURLString(for updater: SPUUpdater) -> String? {
        guard self.updater === updater, installationCycle != nil, let approvedVersion else { return nil }
        return channel.sparkleFeedURL(version: approvedVersion)
    }
    static func validateTarget(actual: String, approved: String?) throws {
        guard let approved, actual == approved else { throw UpdateFailure.invalid(L10n.text("更新源返回的版本与已确认版本不一致。")) }
    }
    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate updateItem: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        do {
            guard self.updater === updater, installationCycle != nil else {
                throw UpdateFailure.invalid(L10n.text("更新源返回的版本与已确认版本不一致。"))
            }
            try Self.validateTarget(actual: updateItem.displayVersionString, approved: approvedVersion)
        } catch {
            finishCycle(for: updater, error: error.localizedDescription)
            throw error
        }
    }
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard self.updater === updater, let token = installationCycle, let version = approvedVersion else {
            // A stale SDK callback must never commit a different/newer cycle.
            // Postpone without invoking its handler rather than allowing relaunch.
            return true
        }
        guard item.displayVersionString == version else {
            finishCycle(for: updater, error: L10n.text("更新源返回的版本与已确认版本不一致。"))
            return true
        }
        guard isTransferActive() else {
            setInstallationCommitting(true)
            return !isCurrentCycle(updater, token: token, version: version)
        }
        deferredRelaunch?.cancel()
        deferredRelaunch = Task { @MainActor [weak self, weak updater] in
            while !Task.isCancelled {
                guard let self, let updater, self.isCurrentCycle(updater, token: token, version: version) else { return }
                if !self.isTransferActive() {
                    self.setInstallationCommitting(true)
                    guard self.isCurrentCycle(updater, token: token, version: version), !Task.isCancelled else { return }
                    self.deferredRelaunch = nil
                    installHandler()
                    return
                }
                do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
            }
        }
        return true
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        finishCycle(for: updater, error: error.localizedDescription)
    }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        finishCycle(for: updater, error: error?.localizedDescription)
    }
    private func isCurrentCycle(_ candidate: SPUUpdater, token: UUID, version: String) -> Bool {
        updater === candidate && installationCycle == token && approvedVersion == version
    }
    private func revokeCurrentApproval() {
        approvedVersion = nil; installationCycle = nil
        userDriver?.revokeInstallationApproval()
        deferredRelaunch?.cancel(); deferredRelaunch = nil
        setInstallationCommitting(false)
    }
    private func finishCycle(for candidate: SPUUpdater, error: String?) {
        guard updater === candidate, installationCycle != nil else { return }
        revokeCurrentApproval()
        cycleFinished(error)
    }
}
