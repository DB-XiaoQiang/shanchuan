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
    public static let languageDidChange = Notification.Name("ShanchuanApplicationLanguageDidChange")
    public static var language: AppLanguage { state.withLock { $0.selected } }

    /// 参数默认逐字保留；只有调用方明确标记的当前 UI 文本才保留其本地化来源。
    public enum StateArgument {
        case literal(String)
        case localized(String)
        case snapshot(Snapshot)
        case time(Date)
    }

    fileprivate indirect enum Argument {
        case value(CVarArg)
        case localized(Snapshot)
        case time(Date)
        func render(language: AppLanguage) -> CVarArg {
            switch self {
            case .value(let value): return value
            case .localized(let snapshot): return snapshot.render(language: language)
            case .time(let value): return value.formatted(Date.FormatStyle(date: .omitted, time: .standard).locale(language.locale))
            }
        }
        var estimatedBytes: Int {
            switch self {
            case .value(let value): return String(describing: value).utf8.count
            case .localized(let snapshot): return snapshot.estimatedBytes
            case .time: return 16
            }
        }
    }
    fileprivate struct Message {
        var source: String
        var arguments: [Argument]?
        func render(language: AppLanguage) -> String {
            let translated = L10n.translation(source, language: language)
            guard let arguments else { return translated }
            return String(format: translated, locale: language.locale,
                          arguments: arguments.map { $0.render(language: language) })
        }
        var estimatedBytes: Int { source.utf8.count + (arguments?.reduce(0) { $0 + $1.estimatedBytes } ?? 0) }
    }
    private struct Entry {
        var snapshot: Snapshot
        var lastAccess: UInt64
        var bytes: Int
    }
    // Foundation 格式参数只在此锁内读取/保存；不把共享可变状态交给 UI 或后台任务。
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        let selectionLock = NSLock()
        var selected = AppLanguage.resolve(UserDefaults.standard.string(forKey: AppLanguage.preferenceKey))
        var messages: [String: Entry] = [:]
        var clock: UInt64 = 0
        var bytes = 0
        static let maximumEntries = 2048
        static let maximumBytes = 8 * 1024 * 1024
        func withLock<T>(_ body: (State) -> T) -> T {
            lock.lock(); defer { lock.unlock() }
            return body(self)
        }
        func lookup(_ rendered: String) -> Snapshot? {
            guard var entry = messages[rendered] else { return nil }
            clock &+= 1; entry.lastAccess = clock; messages[rendered] = entry
            return entry.snapshot
        }
        func remember(_ rendered: String, snapshot: Snapshot) {
            let cost = rendered.utf8.count + snapshot.estimatedBytes
            guard cost <= Self.maximumBytes else { return }
            if let previous = messages.removeValue(forKey: rendered) { bytes -= previous.bytes }
            clock &+= 1
            messages[rendered] = Entry(snapshot: snapshot, lastAccess: clock, bytes: cost)
            bytes += cost
            while messages.count > Self.maximumEntries || bytes > Self.maximumBytes {
                guard let oldest = messages.min(by: { $0.value.lastAccess < $1.value.lastAccess }) else { break }
                bytes -= oldest.value.bytes; messages.removeValue(forKey: oldest.key)
            }
        }
    }
    private static let state = State()
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
        state.selectionLock.lock(); defer { state.selectionLock.unlock() }
        defaults.set([selected.rawValue], forKey: "AppleLanguages")
        state.withLock { $0.selected = selected }
    }

    public static func setLanguage(_ selected: AppLanguage, defaults: UserDefaults = .standard) {
        state.selectionLock.lock()
        defaults.set(selected.rawValue, forKey: AppLanguage.preferenceKey)
        defaults.set([selected.rawValue], forKey: "AppleLanguages")
        let changed = state.withLock { state in
            let changed = state.selected != selected
            state.selected = selected
            return changed
        }
        state.selectionLock.unlock()
        if changed { NotificationCenter.default.post(name: languageDidChange, object: selected.rawValue) }
    }

    private static func translation(_ source: String, language selected: AppLanguage) -> String {
        guard let path = resources.path(forResource: selected.rawValue, ofType: "lproj")
                ?? resources.path(forResource: selected.rawValue.lowercased(), ofType: "lproj"),
              let localized = Bundle(path: path) else { return source }
        return localized.localizedString(forKey: source, value: source, table: "Localizable")
    }

    /// 当前 UI 字段可以独立持有此不可变来源，不依赖兼容缓存的保留时间或相同输出。
    public struct Snapshot: @unchecked Sendable {
        private let message: Message?
        private let literal: String
        private let secrets: [String]
        private let singleLine: Bool
        private let maximumLength: Int?
        fileprivate init(message: Message?, literal: String = "", secrets: [String] = [],
                         singleLine: Bool = false, maximumLength: Int? = nil) {
            self.message = message; self.literal = literal; self.secrets = secrets
            self.singleLine = singleLine; self.maximumLength = maximumLength
        }
        public static func verbatim(_ text: String) -> Snapshot { Snapshot(message: nil, literal: text) }
        public var rendered: String {
            state.withLock { state in
                let value = render(language: state.selected)
                if message != nil { state.remember(value, snapshot: self) }
                return value
            }
        }
        fileprivate func render(language: AppLanguage) -> String {
            var value = message?.render(language: language) ?? literal
            for secret in secrets where !secret.isEmpty {
                value = value.replacingOccurrences(of: secret,
                    with: L10n.translation("[已隐藏]", language: language))
            }
            if singleLine { value = value.components(separatedBy: .controlCharacters).joined(separator: " ") }
            if let maximumLength { value = String(value.prefix(max(0, maximumLength))) }
            return value
        }
        fileprivate var estimatedBytes: Int {
            (message?.estimatedBytes ?? literal.utf8.count) + secrets.reduce(0) { $0 + $1.utf8.count }
        }
        public func appending(_ suffix: Snapshot) -> Snapshot {
            Snapshot(message: Message(source: "%@%@", arguments: [.localized(self), .localized(suffix)]))
        }
        /// 在每次重绘时重新清理最终文本，切换语言也不会绕过密码隐藏、单行或长度限制。
        public func sanitized(secrets: [String] = [], singleLine: Bool = false, maximumLength: Int? = nil) -> Snapshot {
            Snapshot(message: message, literal: literal, secrets: self.secrets + secrets,
                     singleLine: self.singleLine || singleLine,
                     maximumLength: [self.maximumLength, maximumLength].compactMap { $0 }.min())
        }
    }

    public static func snapshot(_ source: String) -> Snapshot {
        Snapshot(message: Message(source: source, arguments: nil))
    }
    public static func snapshotFormat(_ source: String, _ arguments: CVarArg...) -> Snapshot {
        Snapshot(message: Message(source: source, arguments: arguments.map { .value(frozen($0)) }))
    }
    public static func snapshotCompose(_ source: String, _ arguments: StateArgument...) -> Snapshot {
        state.withLock { state in
            let values: [Argument] = arguments.map {
                switch $0 {
                case .literal(let text): return .value(text)
                case .snapshot(let snapshot): return .localized(snapshot)
                case .time(let date): return .time(date)
                case .localized(let text):
                    return state.lookup(text).map(Argument.localized) ?? .value(text)
                }
            }
            return Snapshot(message: Message(source: source, arguments: values))
        }
    }
    private static func frozen(_ argument: CVarArg) -> CVarArg {
        // 标准数值和 Swift String 是值；显式复制可变 NSString，避免后台修改格式参数。
        if let text = argument as? String { return String(text) }
        if let text = argument as? NSString { return String(text) }
        return argument
    }
    /// 兼容已有 String 边界；当前 UI 应在赋值时捕获，之后持有快照而不是依赖缓存。
    public static func capture(_ rendered: String) -> Snapshot {
        state.withLock { $0.lookup(rendered) ?? .verbatim(rendered) }
    }
    public static func text(_ source: String, language selected: AppLanguage? = nil) -> String {
        render(snapshot(source), language: selected)
    }
    public static func format(_ source: String, _ arguments: CVarArg...) -> String {
        render(Snapshot(message: Message(source: source, arguments: arguments.map { .value(frozen($0)) })), language: nil)
    }
    public static func format(_ source: String, language: AppLanguage, arguments: [CVarArg]) -> String {
        render(Snapshot(message: Message(source: source, arguments: arguments.map { .value(frozen($0)) })), language: language)
    }
    private static func render(_ snapshot: Snapshot, language selected: AppLanguage?) -> String {
        state.withLock { state in
            let rendered = snapshot.render(language: selected ?? state.selected)
            state.remember(rendered, snapshot: snapshot)
            return rendered
        }
    }
    public static func compose(_ source: String, _ arguments: StateArgument...) -> String {
        state.withLock { state in
            let values: [Argument] = arguments.map {
                switch $0 {
                case .literal(let text): return .value(text)
                case .snapshot(let snapshot): return .localized(snapshot)
                case .time(let date): return .time(date)
                case .localized(let text): return state.lookup(text).map(Argument.localized) ?? .value(text)
                }
            }
            let snapshot = Snapshot(message: Message(source: source, arguments: values))
            let rendered = snapshot.render(language: state.selected)
            state.remember(rendered, snapshot: snapshot)
            return rendered
        }
    }
    /// 仅供已生成状态的兼容边界；字段级 Snapshot 可在缓存淘汰后仍正确重绘。
    public static func display(_ rendered: String) -> String {
        state.withLock { state in
            guard let snapshot = state.lookup(rendered) else { return rendered }
            let translated = snapshot.render(language: state.selected)
            state.remember(translated, snapshot: snapshot)
            return translated
        }
    }

    public static func date(_ value: Date, date: Date.FormatStyle.DateStyle = .abbreviated,
                            time: Date.FormatStyle.TimeStyle = .standard) -> String {
        value.formatted(Date.FormatStyle(date: date, time: time).locale(language.locale))
    }

    // 内部测试入口不改变当前语言或任何持久化设置。
    static func clearDisplayCache() { state.withLock { $0.messages.removeAll(); $0.bytes = 0; $0.clock = 0 } }
    static var displayCacheCount: Int { state.withLock { $0.messages.count } }
    static var displayCacheBytes: Int { state.withLock { $0.bytes } }
}
