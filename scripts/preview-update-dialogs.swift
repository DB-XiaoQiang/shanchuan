import AppKit
import Sparkle

/// 仅预览真实用户界面；不创建 SPUUpdater，不联网，不调用安装或重启 API。
@MainActor private final class UpdatePreviewDelegate: NSObject, NSApplicationDelegate {
    private var host: NSWindow?
    private var driver: LocalizedUpdateUserDriver?
    private let language = NSSegmentedControl(labels: ["简体中文", "English"], trackingMode: .selectOne, target: nil, action: nil)
    private let resultLabel = NSTextField(wrappingLabelWithString: "预览，不会安装 / Preview — no installation")
    private var driverCount = 0
    private var callbackCount = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 220),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "闪传更新界面预览（不会安装） / Update Dialog Preview"
        window.identifier = NSUserInterfaceItemIdentifier("ShanchuanUpdatePreviewHost")
        window.isReleasedWhenClosed = false
        if let screen = NSScreen.main { window.setFrameTopLeftPoint(NSPoint(x: screen.visibleFrame.minX + 60, y: screen.visibleFrame.maxY - 60)) }
        language.selectedSegment = L10n.language == .english ? 1 : 0
        language.target = self; language.action = #selector(changeLanguage)
        language.setAccessibilityIdentifier("preview.language")
        let ready = NSButton(title: "准备安装弹框 / Ready to Install", target: self, action: #selector(showReady))
        let extraction = NSButton(title: "解压进度 / Extraction", target: self, action: #selector(showExtraction))
        let error = NSButton(title: "错误弹框 / Error", target: self, action: #selector(showError))
        let buttons = NSStackView(views: [ready, extraction, error])
        buttons.orientation = .horizontal; buttons.spacing = 10
        resultLabel.isSelectable = true
        resultLabel.setAccessibilityIdentifier("preview.result")
        let stack = NSStackView(views: [resultLabel, language, buttons])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        if let container = window.contentView {
            container.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 22),
                stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -22),
                stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 22),
                resultLabel.widthAnchor.constraint(equalToConstant: 606),
            ])
        }
        host = window
        let menu = NSMenu(), applicationMenu = NSMenu(), applicationItem = NSMenuItem()
        let chinese = NSMenuItem(title: "简体中文", action: #selector(selectChinese), keyEquivalent: "1")
        chinese.target = self; chinese.keyEquivalentModifierMask = .command
        let english = NSMenuItem(title: "English", action: #selector(selectEnglish), keyEquivalent: "2")
        english.target = self; english.keyEquivalentModifierMask = .command
        let controls = NSMenuItem(title: "显示预览控制 / Show Preview Controls", action: #selector(showControls), keyEquivalent: "0")
        controls.target = self; controls.keyEquivalentModifierMask = .command
        applicationMenu.addItem(chinese)
        applicationMenu.addItem(english)
        applicationMenu.addItem(controls)
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: "退出预览 / Quit Preview", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationItem.submenu = applicationMenu; menu.addItem(applicationItem); NSApp.mainMenu = menu
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        showReady()
    }
    private func nextDriver() -> LocalizedUpdateUserDriver {
        driver?.dismissUpdateInstallation()
        let selected: AppLanguage = language.selectedSegment == 1 ? .english : .simplifiedChinese
        L10n.setLanguage(selected)
        let name = "预览，不会安装 / PREVIEW — NO INSTALLATION"
        let next = LocalizedUpdateUserDriver(language: selected, applicationName: name)
        driver = next; driverCount += 1
        return next
    }
    @objc private func changeLanguage() {
        let selected: AppLanguage = language.selectedSegment == 1 ? .english : .simplifiedChinese
        L10n.setLanguage(selected)
        resultLabel.stringValue = "同一驱动实例 \(driverCount)，回调 \(callbackCount) 次；仅切换文字。 / Same driver, text changed only; no installation."
    }
    @objc private func selectChinese() { language.selectedSegment = 0; changeLanguage() }
    @objc private func selectEnglish() { language.selectedSegment = 1; changeLanguage() }
    @objc private func showControls() { host?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc private func showReady() {
        nextDriver().showReady(toInstallAndRelaunch: { [weak self] choice in
            self?.callbackCount += 1
            self?.resultLabel.stringValue = "预览回调：\(choice.rawValue)；未执行安装或重启。 / Preview callback only; no installation or relaunch."
            self?.host?.makeKeyAndOrderFront(nil)
        })
    }
    @objc private func showExtraction() {
        let next = nextDriver()
        next.showDownloadDidStartExtractingUpdate()
        next.showExtractionReceivedProgress(0.6)
    }
    @objc private func showError() {
        nextDriver().showUpdaterError(NSError(domain: "ShanchuanPreviewOnly", code: 0,
            userInfo: [NSLocalizedDescriptionKey: "仅为错误界面预览；没有发生真实更新错误。 / Preview only; no actual update failed."]), acknowledgement: { [weak self] in
                self?.resultLabel.stringValue = "已关闭错误预览，没有执行更新。 / Error preview closed; no update performed."
                self?.host?.makeKeyAndOrderFront(nil)
            })
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { driver?.dismissUpdateInstallation() }
}

@main private enum UpdateDialogPreview {
    @MainActor static func main() {
        L10n.configureProcessLanguage()
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let delegate = UpdatePreviewDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
