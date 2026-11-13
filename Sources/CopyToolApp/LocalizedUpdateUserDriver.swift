import AppKit
import CopyToolCore
import Sparkle

/// 只实现 Sparkle 公开用户交互协议；后端仍负责下载、验签、系统授权和替换。
/// 文本保留结构化来源，切换语言时只重绘同一界面，不触碰 Sparkle 授权或状态。
@MainActor final class LocalizedUpdateUserDriver: NSObject, SPUUserDriver {
    enum Phase: Equatable { case idle, checking, found, downloading, extracting, ready, installing, error, finished }
    private(set) var language: AppLanguage
    private var strings: SparkleDialogStrings
    private let applicationName: (AppLanguage) -> String
    private let presenter: UpdateDialogPresenting
    private(set) var phase: Phase = .idle
    private var content = UpdateDialogContent()
    var presentation: UpdateDialogPresentation { content.render(strings: strings, applicationName: applicationName(language)) }
    private var primaryAction: (() -> Void)?
    private var secondaryAction: (() -> Void)?
    private var closeAction: (() -> Void)?
    private var interaction = UUID()
    private var downloaded: UInt64 = 0
    private var expected: UInt64 = 0
    private var targetVersion = ""
    private var languageObserver: NSObjectProtocol?
    private var isPresented = false

    init(language: AppLanguage, applicationName: String, applicationNameProvider: ((AppLanguage) -> String)? = nil,
         presenter: UpdateDialogPresenting? = nil) {
        self.language = language; strings = SparkleDialogStrings(language: language)
        self.applicationName = applicationNameProvider ?? { _ in applicationName }
        self.presenter = presenter ?? LocalizedUpdateWindow()
        super.init()
        languageObserver = NotificationCenter.default.addObserver(forName: L10n.languageDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshLanguage(L10n.language) }
        }
    }
    deinit { if let languageObserver { NotificationCenter.default.removeObserver(languageObserver) } }
    private func refreshLanguage(_ selected: AppLanguage) {
        guard selected != language else { return }
        language = selected; strings = SparkleDialogStrings(language: selected)
        if isPresented { render() }
    }
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // 独立协调器负责每日检查；Sparkle 不另行检查、自动安装或上传系统画像。
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, automaticUpdateDownloading: false, sendSystemProfile: false))
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        phase = .checking
        set(title: .sdk("Checking for updates…"), progress: nil, showsProgress: true,
            secondary: .sdk("Cancel"), secondaryAction: cancellation, closeAction: cancellation)
    }
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        showFound(version: appcastItem.displayVersionString, informationOnly: appcastItem.isInformationOnlyUpdate,
            stage: state.stage, reply: reply)
    }
    func showFound(version: String, informationOnly: Bool, stage: SPUUserUpdateStage,
                   reply: @escaping (SPUUserUpdateChoice) -> Void) {
        phase = .found; targetVersion = version
        let cancel: SPUUserUpdateChoice = stage == .installing ? .skip : .dismiss
        if informationOnly {
            set(title: .sdkFormat("A new version of %@ is available!", [.applicationName]),
                body: .joined([.literal(version), .app("此版本仅提供更新信息，未执行安装。")], separator: "\n"),
                primary: .sdk("OK"), primaryAction: { reply(cancel) }, closeAction: { reply(cancel) })
        } else {
            set(title: .sdkFormat("A new version of %@ is available!", [.applicationName]), body: .literal(version),
                primary: .sdk(stage == .installing ? "Install and Relaunch" : "Install Update"),
                secondary: .sdk("Remind Me Later"), primaryAction: { reply(.install) },
                secondaryAction: { reply(cancel) }, closeAction: { reply(cancel) })
        }
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        // 不解析或渲染远端 HTML；更新说明已在经过清单验签的应用确认框中展示。
    }
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        // 说明下载失败不改变安装选择；下次终止性错误仍通过完整错误入口展示。
    }
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        phase = .finished
        let reason = (error as NSError).userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber
        let title: UpdateDialogText
        switch reason?.int32Value {
        case SPUNoUpdateFoundReason.onLatestVersion.rawValue, SPUNoUpdateFoundReason.onNewerThanLatestVersion.rawValue:
            title = .sdk("You’re up to date!")
        case SPUNoUpdateFoundReason.systemIsTooOld.rawValue: title = .sdk("Your macOS version is too old")
        case SPUNoUpdateFoundReason.systemIsTooNew.rawValue: title = .sdk("Your macOS version is too new")
        case SPUNoUpdateFoundReason.hardwareDoesNotSupportARM64.rawValue: title = .sdk("Your Mac is too old")
        default: title = .sdk("Unable to Check For Updates")
        }
        set(title: title, body: .app("未发现可安装的更新。可稍后重新检查。"),
            details: (error as NSError).localizedDescription, primary: .sdk("OK"),
            primaryAction: acknowledgement, closeAction: acknowledgement)
    }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        phase = .error
        set(title: .sdk("Update Error!"), body: .app("更新未完成，请稍后重试。"),
            details: (error as NSError).localizedDescription, primary: .sdk("Cancel Update"),
            primaryAction: acknowledgement, closeAction: acknowledgement)
    }
    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        phase = .downloading; downloaded = 0; expected = 0
        set(title: .sdk("Downloading update…"), progress: nil, showsProgress: true,
            secondary: .sdk("Cancel"), secondaryAction: cancellation, closeAction: cancellation)
    }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        guard phase == .downloading else { return }
        expected = expectedContentLength; updateDownloadProgress()
    }
    func showDownloadDidReceiveData(ofLength length: UInt64) {
        guard phase == .downloading else { return }
        let (total, overflow) = downloaded.addingReportingOverflow(length)
        downloaded = overflow ? UInt64.max : total
        updateDownloadProgress()
    }
    private func updateDownloadProgress() {
        content.progress = expected > 0 ? min(Double(downloaded) / Double(expected), 1) : nil
        // 数字和 SI 单位不含宿主系统语言；说明文字由当前流程的显式语言资源提供。
        let amount = Self.bytes(downloaded)
        content.body = expected > 0 ? .sdkFormat("%@ of %@", [.literal(amount), .literal(Self.bytes(max(downloaded, expected)))])
            : .sdkFormat("%@ downloaded", [.literal(amount)])
        render()
    }
    static func bytes(_ value: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var amount = Double(value); var index = 0
        while amount >= 1000 && index < units.count - 1 { amount /= 1000; index += 1 }
        return String(format: index == 0 ? "%.0f %@" : "%.1f %@", locale: Locale(identifier: "en_US_POSIX"), amount, units[index])
    }
    func showDownloadDidStartExtractingUpdate() {
        phase = .extracting
        set(title: .sdk("Extracting update…"), progress: 0, showsProgress: true, allowsClose: false)
    }
    func showExtractionReceivedProgress(_ progress: Double) {
        guard phase == .extracting else { return }
        content.progress = progress.isFinite ? max(0, min(1, progress)) : 0
        render()
    }
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        phase = .ready
        // Sparkle 的 dismiss 可能保留退出时安装；“稍后”和关闭必须明确 skip 取消本轮安装。
        set(title: .sdk("Ready to Install"), body: .literal(targetVersion), progress: 1, showsProgress: true,
            primary: .sdk("Install and Relaunch"), secondary: .sdk("Remind Me Later"),
            primaryAction: { reply(.install) }, secondaryAction: { reply(.skip) }, closeAction: { reply(.skip) })
    }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        phase = .installing
        set(title: .sdk("Installing update…"), progress: nil, showsProgress: true,
            primary: applicationTerminated ? nil : .app("退出并安装"), allowsClose: false,
            primaryAction: applicationTerminated ? nil : retryTerminatingApplication)
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        phase = .finished
        if relaunched { dismissUpdateInstallation(); acknowledgement() }
        else { set(title: .sdk("Update Installed"), primary: .sdk("OK"), primaryAction: acknowledgement, closeAction: acknowledgement) }
    }
    func dismissUpdateInstallation() {
        clearActions(); phase = .idle; isPresented = false; presenter.close()
    }
    func showUpdateInFocus() { presenter.focus() }

    private func set(title: UpdateDialogText, body: UpdateDialogText = .literal(""), details: String = "", progress: Double? = nil,
                     showsProgress: Bool = false, primary: UpdateDialogText? = nil, secondary: UpdateDialogText? = nil,
                     allowsClose: Bool = true, primaryAction: (() -> Void)? = nil,
                     secondaryAction: (() -> Void)? = nil, closeAction: (() -> Void)? = nil) {
        interaction = UUID()
        self.primaryAction = primaryAction; self.secondaryAction = secondaryAction; self.closeAction = closeAction
        content = UpdateDialogContent(title: title, body: body, details: details, progress: progress,
            showsProgress: showsProgress, primary: primary, secondary: secondary, allowsClose: allowsClose)
        render()
    }
    private func render() {
        let token = interaction
        presenter.show(presentation, activate: !isPresented, primary: primaryAction == nil ? nil : { [weak self] in
            guard let self, self.interaction == token else { return }; self.performPrimary()
        }, secondary: secondaryAction == nil ? nil : { [weak self] in
            guard let self, self.interaction == token else { return }; self.performSecondary()
        }, close: { [weak self] in
            guard let self, self.interaction == token else { return }; self.performClose()
        })
        isPresented = true
    }
    func performPrimary() { perform(primaryAction) }
    func performSecondary() { perform(secondaryAction) }
    func performClose() { guard presentation.allowsClose else { return }; perform(closeAction) }
    private func perform(_ action: (() -> Void)?) {
        guard let action else { return }
        // 先消费所有按钮授权，再调用 SDK；重入/双击/旧窗口按钮不会重复批准或取消。
        clearActions(); phase = .idle; isPresented = false; presenter.close(); action()
    }
    private func clearActions() { interaction = UUID(); primaryAction = nil; secondaryAction = nil; closeAction = nil }
}
