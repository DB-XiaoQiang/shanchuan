import Foundation

// 纯命令行探针：复用真实 L10n 启动逻辑，读取 Sparkle 资源，不创建 NSApplication 或更新器。
let probeIdentifier = Bundle.main.bundleIdentifier ?? ""
guard probeIdentifier.hasPrefix("local.shanchuan.localization-probe.") else {
    fatalError("探针只能使用独立临时偏好域。")
}
defer {
    UserDefaults.standard.removePersistentDomain(forName: probeIdentifier)
    UserDefaults.standard.synchronize()
}
let requestedLanguage = CommandLine.arguments[1]
if requestedLanguage != "default" {
    UserDefaults.standard.set(requestedLanguage, forKey: AppLanguage.preferenceKey)
}
L10n.configureProcessLanguage()
guard let sparkle = Bundle(path: CommandLine.arguments[2]) else {
    fatalError("找不到 Sparkle 资源包。")
}
let keys = ["Updating %@", "Ready to Install", "Install and Relaunch"]
let catalogKeys = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[5])))
let coreKeys = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[6])))
var result: [String: Any] = [
    "requestedLanguage": requestedLanguage,
    "appLanguage": L10n.language.rawValue,
    "appleLanguages": UserDefaults.standard.stringArray(forKey: "AppleLanguages") ?? [],
    "hostLocalizations": Bundle.main.preferredLocalizations,
    "sparkleLocalizations": sparkle.preferredLocalizations,
    "sparkleStrings": keys.map { sparkle.localizedString(forKey: $0, value: $0, table: "Sparkle") },
    "sparkleCatalog": Dictionary(uniqueKeysWithValues: catalogKeys.map { ($0, sparkle.localizedString(forKey: $0, value: $0, table: "Sparkle")) }),
    "coreCatalog": Dictionary(uniqueKeysWithValues: coreKeys.map { ($0, L10n.text($0)) }),
    "checkForUpdates": L10n.text("检查更新"),
]
if CommandLine.arguments[4] != "-", let host = Bundle(path: CommandLine.arguments[4]) {
    result["hostDisplayName"] = host.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? ""
}
let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
print(String(decoding: data, as: UTF8.self))
