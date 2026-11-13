import AppKit
import CopyToolCore
import Sparkle

/// 显式读取语言子包，不依赖已被 Foundation 缓存的 Sparkle 主包语言。
struct SparkleDialogStrings {
    let language: AppLanguage
    private let bundle: Bundle?
    init(language: AppLanguage) {
        self.language = language
        let directory = language == .simplifiedChinese ? "zh_CN" : "Base"
        bundle = Bundle(for: SPUUpdater.self).resourceURL
            .flatMap { Bundle(url: $0.appendingPathComponent(directory + ".lproj")) }
    }
    func text(_ key: String) -> String { bundle?.localizedString(forKey: key, value: key, table: "Sparkle") ?? key }
    func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: language.locale, arguments: arguments)
    }
    func appText(_ key: String) -> String { L10n.text(key, language: language) }
}

struct UpdateDialogPresentation: Equatable {
    var windowTitle: String
    var title: String
    var body = ""
    var details = ""
    var detailsTitle = ""
    var progress: Double?
    var showsProgress = false
    var primaryTitle: String?
    var secondaryTitle: String?
    var allowsClose = true
}

enum UpdateDialogArgument {
    case literal(String)
    case applicationName
    func value(applicationName: String) -> String {
        switch self { case .literal(let value): return value; case .applicationName: return applicationName }
    }
}

/// 保留文本的明确来源；语言改变不通过已显示字符串反查，也不翻译用户数据。
indirect enum UpdateDialogText {
    case literal(String)
    case sdk(String)
    case sdkFormat(String, [UpdateDialogArgument])
    case app(String)
    case joined([UpdateDialogText], separator: String)
    func render(strings: SparkleDialogStrings, applicationName: String) -> String {
        switch self {
        case .literal(let value): return value
        case .sdk(let key): return strings.text(key)
        case .sdkFormat(let key, let arguments):
            return String(format: strings.text(key), locale: strings.language.locale,
                arguments: arguments.map { $0.value(applicationName: applicationName) })
        case .app(let key): return strings.appText(key)
        case .joined(let values, let separator):
            return values.map { $0.render(strings: strings, applicationName: applicationName) }.joined(separator: separator)
        }
    }
}

struct UpdateDialogContent {
    var title: UpdateDialogText = .literal("")
    var body: UpdateDialogText = .literal("")
    var details = ""
    var progress: Double?
    var showsProgress = false
    var primary: UpdateDialogText?
    var secondary: UpdateDialogText?
    var allowsClose = true
    func render(strings: SparkleDialogStrings, applicationName: String) -> UpdateDialogPresentation {
        UpdateDialogPresentation(windowTitle: strings.format("Updating %@", applicationName),
            title: title.render(strings: strings, applicationName: applicationName),
            body: body.render(strings: strings, applicationName: applicationName), details: details,
            detailsTitle: strings.appText("错误详情（原始信息）"), progress: progress, showsProgress: showsProgress,
            primaryTitle: primary?.render(strings: strings, applicationName: applicationName),
            secondaryTitle: secondary?.render(strings: strings, applicationName: applicationName), allowsClose: allowsClose)
    }
}

@MainActor protocol UpdateDialogPresenting: AnyObject {
    func show(_ presentation: UpdateDialogPresentation, activate: Bool, primary: (() -> Void)?, secondary: (() -> Void)?, close: @escaping () -> Void)
    func close()
    func focus()
}

/// 用原生 AppKit 控件展示状态；不下载、验签、替换应用或调用安装器。
@MainActor final class LocalizedUpdateWindow: NSObject, UpdateDialogPresenting, NSWindowDelegate {
    private var window: NSWindow?
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private let detailTitle = NSTextField(labelWithString: "")
    private let detailScroll = NSScrollView()
    private let detailText = NSTextView()
    private let primaryButton = NSButton(title: "", target: nil, action: nil)
    private let secondaryButton = NSButton(title: "", target: nil, action: nil)
    private var primaryAction: (() -> Void)?
    private var secondaryAction: (() -> Void)?
    private var closeAction: (() -> Void)?
    private var allowsClose = true
    private var layoutStack: NSStackView?

    func show(_ presentation: UpdateDialogPresentation, activate: Bool, primary: (() -> Void)?, secondary: (() -> Void)?, close: @escaping () -> Void) {
        buildWindowIfNeeded()
        primaryAction = primary; secondaryAction = secondary; closeAction = close
        allowsClose = presentation.allowsClose
        window?.title = presentation.windowTitle
        titleLabel.stringValue = presentation.title
        bodyLabel.stringValue = presentation.body
        bodyLabel.isHidden = presentation.body.isEmpty
        detailTitle.stringValue = presentation.detailsTitle
        detailTitle.isHidden = presentation.details.isEmpty
        detailScroll.isHidden = presentation.details.isEmpty
        if detailText.string != presentation.details { detailText.string = presentation.details }
        progress.isHidden = !presentation.showsProgress
        progress.isIndeterminate = presentation.progress == nil
        if let value = presentation.progress { progress.stopAnimation(nil); progress.doubleValue = max(0, min(1, value)) }
        else if presentation.showsProgress { progress.startAnimation(nil) }
        else { progress.stopAnimation(nil) }
        primaryButton.title = presentation.primaryTitle ?? ""
        primaryButton.isHidden = presentation.primaryTitle == nil
        primaryButton.isEnabled = primary != nil
        secondaryButton.title = presentation.secondaryTitle ?? ""
        secondaryButton.isHidden = presentation.secondaryTitle == nil
        secondaryButton.isEnabled = secondary != nil
        window?.standardWindowButton(.closeButton)?.isEnabled = presentation.allowsClose
        window?.contentView?.layoutSubtreeIfNeeded()
        if let layoutStack { window?.setContentSize(NSSize(width: 560, height: max(180, layoutStack.fittingSize.height + 44))) }
        if activate { window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    }
    func close() {
        primaryAction = nil; secondaryAction = nil; closeAction = nil
        progress.stopAnimation(nil)
        window?.orderOut(nil)
    }
    func focus() { window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard allowsClose else { return false }
        closeAction?()
        return false
    }
    @objc private func primaryPressed() { primaryAction?() }
    @objc private func secondaryPressed() { secondaryAction?() }

    private func buildWindowIfNeeded() {
        guard window == nil else { return }
        let result = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 300),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        result.identifier = NSUserInterfaceItemIdentifier("ShanchuanLocalizedUpdate")
        result.isReleasedWhenClosed = false
        result.delegate = self
        result.center()
        let icon = NSImageView()
        icon.image = NSImage(named: NSImage.applicationIconName)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 56), icon.heightAnchor.constraint(equalToConstant: 56)])
        titleLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        titleLabel.setAccessibilityIdentifier("update.title")
        bodyLabel.isSelectable = true
        bodyLabel.maximumNumberOfLines = 8
        bodyLabel.setAccessibilityIdentifier("update.body")
        progress.style = .bar; progress.minValue = 0; progress.maxValue = 1
        progress.setAccessibilityIdentifier("update.progress")
        detailTitle.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailText.isEditable = false; detailText.isSelectable = true
        detailText.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        detailText.frame = NSRect(x: 0, y: 0, width: 440, height: 86)
        detailText.isVerticallyResizable = true; detailText.isHorizontallyResizable = false
        detailText.autoresizingMask = [.width]
        detailText.textContainer?.widthTracksTextView = true
        detailScroll.documentView = detailText
        detailScroll.hasVerticalScroller = true
        detailScroll.heightAnchor.constraint(equalToConstant: 86).isActive = true
        primaryButton.target = self; primaryButton.action = #selector(primaryPressed)
        primaryButton.bezelStyle = .rounded; primaryButton.keyEquivalent = "\r"
        primaryButton.setAccessibilityIdentifier("update.primary")
        secondaryButton.target = self; secondaryButton.action = #selector(secondaryPressed)
        secondaryButton.bezelStyle = .rounded; secondaryButton.keyEquivalent = "\u{1b}"
        secondaryButton.setAccessibilityIdentifier("update.secondary")
        let buttons = NSStackView(views: [secondaryButton, primaryButton])
        buttons.orientation = .horizontal; buttons.alignment = .centerY; buttons.spacing = 10
        let content = NSStackView(views: [titleLabel, bodyLabel, progress, detailTitle, detailScroll, buttons])
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 12
        let row = NSStackView(views: [icon, content])
        row.orientation = .horizontal; row.alignment = .top; row.spacing = 16
        row.translatesAutoresizingMaskIntoConstraints = false
        layoutStack = row
        guard let container = result.contentView else { return }
        container.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 22),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -22),
            row.topAnchor.constraint(equalTo: container.topAnchor, constant: 22),
            row.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -22),
            content.widthAnchor.constraint(equalToConstant: 440),
            bodyLabel.widthAnchor.constraint(equalTo: content.widthAnchor),
            progress.widthAnchor.constraint(equalTo: content.widthAnchor),
            detailScroll.widthAnchor.constraint(equalTo: content.widthAnchor),
        ])
        result.contentMinSize = NSSize(width: 560, height: 220)
        window = result
    }
}
