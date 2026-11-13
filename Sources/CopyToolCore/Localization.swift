import Foundation

/// 应用语言独立于系统语言；旧安装及未知设置始终使用简体中文。
public enum AppLanguage: String, CaseIterable, Sendable {
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    public static let preferenceKey = "appLanguage"
    public static func resolve(_ value: String?) -> AppLanguage {
        value.flatMap(AppLanguage.init(rawValue:)) ?? .simplifiedChinese
    }
    public var displayName: String { self == .simplifiedChinese ? "简体中文" : "English" }
    public var locale: Locale { Locale(identifier: rawValue) }
}

/// 中文原文是稳定资源键；协议值、文件名及用户输入不得送入翻译表。
public enum L10n {
    public static let language = AppLanguage.resolve(UserDefaults.standard.string(forKey: AppLanguage.preferenceKey))
    static let resources: Bundle = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("CopyTool_CopyToolCore.bundle"),
           let bundled = Bundle(url: url) { return bundled }
        // 已打包应用资源损坏时也不从开发机的构建目录读取旧翻译。
        if Bundle.main.bundleURL.pathExtension == "app" { return Bundle.main }
        #if SWIFT_PACKAGE
        return Bundle.module
        #else
        // 显式 swiftc 的回环/快捷键工具不打包资源，保留中文原文作为回退。
        return Bundle.main
        #endif
    }()

    /// 必须在创建 AppKit/SwiftUI 或 Sparkle 控件之前执行，设置仅限当前应用偏好域。
    public static func configureProcessLanguage(defaults: UserDefaults = .standard) {
        let selected = AppLanguage.resolve(defaults.string(forKey: AppLanguage.preferenceKey))
        defaults.set([selected.rawValue], forKey: "AppleLanguages")
    }

    public static func text(_ source: String, language selected: AppLanguage? = nil) -> String {
        let selected = selected ?? language
        guard let path = resources.path(forResource: selected.rawValue, ofType: "lproj")
                ?? resources.path(forResource: selected.rawValue.lowercased(), ofType: "lproj"),
              let localized = Bundle(path: path) else { return source }
        return localized.localizedString(forKey: source, value: source, table: "Localizable")
    }

    public static func format(_ source: String, _ arguments: CVarArg...) -> String {
        format(source, language: language, arguments: arguments)
    }

    public static func format(_ source: String, language: AppLanguage, arguments: [CVarArg]) -> String {
        String(format: text(source, language: language), locale: language.locale, arguments: arguments)
    }

    public static func date(_ value: Date, date: Date.FormatStyle.DateStyle = .abbreviated,
                            time: Date.FormatStyle.TimeStyle = .standard) -> String {
        value.formatted(Date.FormatStyle(date: date, time: time).locale(language.locale))
    }
}
