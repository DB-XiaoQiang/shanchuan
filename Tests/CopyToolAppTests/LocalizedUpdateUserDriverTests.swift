import AppKit
import CopyToolCore
import Sparkle
import XCTest
@testable import CopyToolApp

@MainActor private final class RecordingUpdatePresenter: UpdateDialogPresenting {
    var latest: UpdateDialogPresentation?
    var primary: (() -> Void)?
    var secondary: (() -> Void)?
    var closed: (() -> Void)?
    var closeCount = 0
    var focusCount = 0
    var showCount = 0
    var activateCount = 0
    func show(_ presentation: UpdateDialogPresentation, activate: Bool, primary: (() -> Void)?, secondary: (() -> Void)?, close: @escaping () -> Void) {
        latest = presentation; self.primary = primary; self.secondary = secondary; closed = close
        showCount += 1
        if activate { activateCount += 1 }
    }
    func close() { closeCount += 1 }
    func focus() { focusCount += 1 }
}

final class LocalizedUpdateUserDriverTests: XCTestCase {
    @MainActor func testExplicitSparkleLanguageChangesInOneProcessWithoutPreferencesMutation() {
        let previous = UserDefaults.standard.stringArray(forKey: "AppleLanguages")
        XCTAssertEqual(SparkleDialogStrings(language: .simplifiedChinese).text("Ready to Install"), "可以开始安装了")
        XCTAssertEqual(SparkleDialogStrings(language: .english).text("Ready to Install"), "Ready to Install")
        XCTAssertEqual(SparkleDialogStrings(language: .simplifiedChinese).text("Install and Relaunch"), "安装并重启应用")
        XCTAssertEqual(SparkleDialogStrings(language: .english).text("Install and Relaunch"), "Install and Relaunch")
        XCTAssertEqual(UserDefaults.standard.stringArray(forKey: "AppleLanguages"), previous)
    }
    @MainActor func testVisibleReadyWindowChangesLanguageWithoutRecreatingStateOrAuthorizing() {
        let suite = "shanchuan-driver-language-test." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let previous = L10n.language
        defer { L10n.setLanguage(previous, defaults: defaults); defaults.removePersistentDomain(forName: suite) }
        let ui = RecordingUpdatePresenter()
        L10n.setLanguage(.simplifiedChinese, defaults: defaults)
        let driver = LocalizedUpdateUserDriver(language: L10n.language, applicationName: "闪传",
            applicationNameProvider: { L10n.text("闪传", language: $0) }, presenter: ui)
        let identity = ObjectIdentifier(driver)
        var choices: [SPUUserUpdateChoice] = []
        driver.showFound(version: "0.2.1", informationOnly: false, stage: .notDownloaded, reply: { choices.append($0) })
        driver.showReady(toInstallAndRelaunch: { choices.append($0) })
        let originalClick = ui.primary
        let activations = ui.activateCount
        XCTAssertEqual(ui.latest?.title, "可以开始安装了")
        L10n.setLanguage(.english, defaults: defaults)
        XCTAssertEqual(ObjectIdentifier(driver), identity)
        XCTAssertEqual(ui.latest?.title, "Ready to Install")
        XCTAssertEqual(ui.latest?.primaryTitle, "Install and Relaunch")
        XCTAssertEqual(ui.latest?.windowTitle, "Updating Shanchuan")
        XCTAssertEqual(ui.latest?.body, "0.2.1")
        XCTAssertEqual(driver.phase, .ready)
        XCTAssertEqual(ui.latest?.progress, 1)
        XCTAssertEqual(ui.activateCount, activations)
        XCTAssertEqual(ui.focusCount, 0)
        XCTAssertTrue(choices.isEmpty)
        L10n.setLanguage(.simplifiedChinese, defaults: defaults)
        XCTAssertEqual(ui.latest?.title, "可以开始安装了")
        originalClick?(); originalClick?(); ui.primary?()
        XCTAssertEqual(choices, [.install], "language changes must preserve the original click token")
        let renders = ui.showCount
        L10n.setLanguage(.english, defaults: defaults)
        XCTAssertEqual(ui.showCount, renders, "changing language must not reopen a dismissed window")
    }
    @MainActor func testVisibleDownloadLanguageChangePreservesProgressAndCancellationWithoutFocus() {
        let suite = "shanchuan-driver-download-language." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!, previous = L10n.language
        defer { L10n.setLanguage(previous, defaults: defaults); defaults.removePersistentDomain(forName: suite) }
        L10n.setLanguage(.simplifiedChinese, defaults: defaults)
        let ui = RecordingUpdatePresenter()
        let driver = LocalizedUpdateUserDriver(language: .simplifiedChinese, applicationName: "Raw Test Name", presenter: ui)
        var canceled = 0
        driver.showDownloadInitiated(cancellation: { canceled += 1 })
        driver.showDownloadDidReceiveExpectedContentLength(100)
        driver.showDownloadDidReceiveData(ofLength: 40)
        let cancel = ui.secondary
        let activation = ui.activateCount
        L10n.setLanguage(.english, defaults: defaults)
        XCTAssertEqual(driver.phase, .downloading)
        XCTAssertEqual(ui.latest?.title, "Downloading update…")
        XCTAssertEqual(ui.latest?.secondaryTitle, "Cancel")
        XCTAssertEqual(ui.latest?.progress, 0.4)
        XCTAssertEqual(ui.latest?.body, "40 B of 100 B")
        XCTAssertEqual(ui.activateCount, activation)
        XCTAssertEqual(ui.focusCount, 0)
        XCTAssertEqual(canceled, 0)
        driver.showDownloadDidReceiveData(ofLength: 10)
        XCTAssertEqual(ui.latest?.progress, 0.5)
        XCTAssertEqual(ui.activateCount, activation, "ordinary progress must not steal focus either")
        cancel?(); ui.closed?()
        XCTAssertEqual(canceled, 1)
    }
    @MainActor func testVisibleErrorLanguageChangePreservesLiteralDetailsAndAcknowledgement() {
        let suite = "shanchuan-driver-error-language." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!, previous = L10n.language
        defer { L10n.setLanguage(previous, defaults: defaults); defaults.removePersistentDomain(forName: suite) }
        L10n.setLanguage(.simplifiedChinese, defaults: defaults)
        let ui = RecordingUpdatePresenter()
        let driver = LocalizedUpdateUserDriver(language: .simplifiedChinese, applicationName: "Raw Name", presenter: ui)
        var acknowledged = 0
        driver.showUpdaterError(NSError(domain: "test", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Ready to Install"]), acknowledgement: { acknowledged += 1 })
        let close = ui.closed
        L10n.setLanguage(.english, defaults: defaults)
        XCTAssertEqual(driver.phase, .error)
        XCTAssertEqual(ui.latest?.title, "Update Error!")
        XCTAssertEqual(ui.latest?.body, "The update did not finish. Please try again later.")
        XCTAssertEqual(ui.latest?.detailsTitle, "Error details (original message)")
        XCTAssertEqual(ui.latest?.details, "Ready to Install", "literal SDK text must never be reverse-translated")
        XCTAssertEqual(ui.latest?.windowTitle, "Updating Raw Name")
        XCTAssertEqual(acknowledged, 0)
        close?(); ui.primary?(); close?()
        XCTAssertEqual(acknowledged, 1)
    }
    @MainActor func testReadyDoesNotApproveUntilExplicitClickAndReplyIsOnceOnly() {
        let ui = RecordingUpdatePresenter()
        let driver = LocalizedUpdateUserDriver(language: .english, applicationName: "Shanchuan", presenter: ui)
        var choices: [SPUUserUpdateChoice] = []
        driver.showReady(toInstallAndRelaunch: { choices.append($0) })
        XCTAssertTrue(choices.isEmpty)
        let oldPrimary = ui.primary, oldClose = ui.closed, oldSecondary = ui.secondary
        oldPrimary?(); oldPrimary?(); oldSecondary?(); oldClose?()
        XCTAssertEqual(choices, [.install])
        XCTAssertEqual(driver.phase, .idle)
    }
    @MainActor func testReadyLaterAndCloseCancelInsteadOfInstallingOnQuit() {
        for close in [true, false] {
            let ui = RecordingUpdatePresenter()
            let driver = LocalizedUpdateUserDriver(language: .simplifiedChinese, applicationName: "闪传", presenter: ui)
            var choices: [SPUUserUpdateChoice] = []
            driver.showReady(toInstallAndRelaunch: { choices.append($0) })
            let action = close ? ui.closed : ui.secondary
            action?(); action?(); driver.performPrimary()
            XCTAssertEqual(choices, [.skip], "dismiss may cause installation on quit; it is forbidden here")
        }
    }
    @MainActor func testFoundDismissAndResumedInstallationCancellationUseCorrectChoices() {
        for stage in [SPUUserUpdateStage.notDownloaded, .downloaded, .installing] {
            let ui = RecordingUpdatePresenter()
            let driver = LocalizedUpdateUserDriver(language: .english, applicationName: "Shanchuan", presenter: ui)
            var choices: [SPUUserUpdateChoice] = []
            driver.showFound(version: "0.2.1", informationOnly: false, stage: stage, reply: { choices.append($0) })
            XCTAssertTrue(choices.isEmpty)
            ui.closed?(); ui.primary?()
            XCTAssertEqual(choices, [stage == .installing ? .skip : .dismiss])
        }
    }
    @MainActor func testInformationOnlyUpdateCannotApproveInstallation() {
        let ui = RecordingUpdatePresenter()
        let driver = LocalizedUpdateUserDriver(language: .english, applicationName: "Shanchuan", presenter: ui)
        var choices: [SPUUserUpdateChoice] = []
        driver.showFound(version: "0.2.1", informationOnly: true, stage: .installing, reply: { choices.append($0) })
        ui.primary?(); ui.closed?()
        XCTAssertEqual(choices, [.skip])
    }
    @MainActor func testCheckAndDownloadCancellationAreOnceOnlyAndLateProgressIsIgnored() {
        let ui = RecordingUpdatePresenter()
        let driver = LocalizedUpdateUserDriver(language: .english, applicationName: "Shanchuan", presenter: ui)
        var canceled = 0
        driver.showUserInitiatedUpdateCheck(cancellation: { canceled += 1 })
        let cancelCheck = ui.closed
        cancelCheck?(); cancelCheck?()
        XCTAssertEqual(canceled, 1)
        driver.showDownloadInitiated(cancellation: { canceled += 1 })
        let cancelDownload = ui.secondary, close = ui.closed
        cancelDownload?(); close?(); driver.performPrimary()
        XCTAssertEqual(canceled, 2)
        let closed = ui.closeCount
        driver.showDownloadDidReceiveData(ofLength: 100)
        XCTAssertEqual(driver.phase, .idle)
        XCTAssertEqual(ui.closeCount, closed)
    }
    @MainActor func testDownloadAndExtractionProgressAreBoundedAndExtractionCannotClose() {
        let ui = RecordingUpdatePresenter()
        let driver = LocalizedUpdateUserDriver(language: .english, applicationName: "Shanchuan", presenter: ui)
        var canceled = false
        driver.showDownloadInitiated(cancellation: { canceled = true })
        XCTAssertNil(driver.presentation.progress)
        driver.showDownloadDidReceiveExpectedContentLength(100)
        driver.showDownloadDidReceiveData(ofLength: 50)
        XCTAssertEqual(driver.presentation.progress, 0.5)
        driver.showDownloadDidReceiveData(ofLength: UInt64.max)
        XCTAssertEqual(driver.presentation.progress, 1)
        XCTAssertEqual(LocalizedUpdateUserDriver.bytes(1500), "1.5 KB")
        driver.showDownloadDidStartExtractingUpdate()
        driver.performClose(); driver.performSecondary()
        XCTAssertFalse(canceled)
        XCTAssertFalse(driver.presentation.allowsClose)
        driver.showExtractionReceivedProgress(2)
        XCTAssertEqual(driver.presentation.progress, 1)
        driver.showExtractionReceivedProgress(.nan)
        XCTAssertEqual(driver.presentation.progress, 0)
    }
    @MainActor func testErrorUsesCapturedSummaryAndOriginalDetailsAndAcknowledgesOnce() {
        let ui = RecordingUpdatePresenter()
        let driver = LocalizedUpdateUserDriver(language: .english, applicationName: "Shanchuan", presenter: ui)
        var acknowledged = 0
        driver.showUpdaterError(NSError(domain: "test", code: 7, userInfo: [NSLocalizedDescriptionKey: "原始 SDK 信息"]), acknowledgement: { acknowledged += 1 })
        XCTAssertEqual(driver.presentation.title, "Update Error!")
        XCTAssertEqual(driver.presentation.body, L10n.text("更新未完成，请稍后重试。", language: .english))
        XCTAssertEqual(driver.presentation.details, "原始 SDK 信息")
        let close = ui.closed, primary = ui.primary
        close?(); primary?(); close?()
        XCTAssertEqual(acknowledged, 1)
    }
    @MainActor func testNotFoundCompatibilityReasonIsNotReportedAsUpToDate() {
        let ui = RecordingUpdatePresenter()
        let driver = LocalizedUpdateUserDriver(language: .english, applicationName: "Shanchuan", presenter: ui)
        var acknowledged = 0
        driver.showUpdateNotFoundWithError(NSError(domain: SUSparkleErrorDomain, code: 1001,
            userInfo: [SPUNoUpdateFoundReasonKey: NSNumber(value: SPUNoUpdateFoundReason.systemIsTooOld.rawValue)]), acknowledgement: { acknowledged += 1 })
        XCTAssertEqual(driver.presentation.title, "Your macOS version is too old")
        ui.primary?(); ui.closed?()
        XCTAssertEqual(acknowledged, 1)
    }
    @MainActor func testRelaunchRetryRequiresClickAndRunsOnceAndInstalledAcknowledgesOnce() {
        let ui = RecordingUpdatePresenter()
        let driver = LocalizedUpdateUserDriver(language: .english, applicationName: "Shanchuan", presenter: ui)
        var retried = 0, acknowledged = 0
        driver.showInstallingUpdate(withApplicationTerminated: false, retryTerminatingApplication: { retried += 1 })
        XCTAssertEqual(retried, 0)
        driver.performClose()
        XCTAssertEqual(retried, 0)
        let retry = ui.primary
        retry?(); retry?()
        XCTAssertEqual(retried, 1)
        driver.showInstallingUpdate(withApplicationTerminated: true, retryTerminatingApplication: { retried += 1 })
        XCTAssertNil(ui.primary)
        driver.showUpdateInstalledAndRelaunched(false, acknowledgement: { acknowledged += 1 })
        let close = ui.closed
        close?(); close?()
        XCTAssertEqual(acknowledged, 1)
        driver.showUpdateInstalledAndRelaunched(true, acknowledgement: { acknowledged += 1 })
        XCTAssertEqual(acknowledged, 2)
    }
    @MainActor func testOldWindowCallbacksAndDismissalNeverApproveNewState() {
        let ui = RecordingUpdatePresenter()
        let driver = LocalizedUpdateUserDriver(language: .english, applicationName: "Shanchuan", presenter: ui)
        var choices: [SPUUserUpdateChoice] = []
        driver.showReady(toInstallAndRelaunch: { choices.append($0) })
        let stalePrimary = ui.primary
        driver.showReady(toInstallAndRelaunch: { choices.append($0) })
        stalePrimary?()
        XCTAssertTrue(choices.isEmpty)
        let current = ui.primary
        driver.dismissUpdateInstallation()
        current?()
        XCTAssertTrue(choices.isEmpty)
        driver.showUpdateInFocus()
        XCTAssertEqual(ui.focusCount, 1)
        XCTAssertNoThrow(try AppUpdater.validateTarget(actual: "0.2.1", approved: "0.2.1"))
        XCTAssertThrowsError(try AppUpdater.validateTarget(actual: "0.2.2", approved: "0.2.1"))
    }
}
