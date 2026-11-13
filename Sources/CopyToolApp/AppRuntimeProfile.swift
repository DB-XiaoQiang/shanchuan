import CopyToolCore
import Foundation

/// 更新测试必须显式标识并隔离；配置有误时也不能回退到生产数据或生产更新源。
struct AppRuntimeProfile: Equatable {
    static let testBundleIdentifier = "local.copytool.update-test"
    static let production = AppRuntimeProfile(isUpdateTest: false, configurationError: nil)
    static let current = load(info: Bundle.main.infoDictionary ?? [:], bundleIdentifier: Bundle.main.bundleIdentifier)

    let isUpdateTest: Bool
    let configurationError: String?
    var applicationName: String { isUpdateTest ? L10n.text("闪传更新测试") : L10n.text("闪传") }
    var dataDirectoryName: String { isUpdateTest ? "CopyToolUpdateTest" : "CopyToolIndependent" }
    var dataRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(dataDirectoryName, isDirectory: true)
    }
    var allowsBusinessTransfers: Bool { !isUpdateTest }
    var updatesEnabled: Bool { configurationError == nil }
    var updateChannel: UpdateChannel {
        guard isUpdateTest else { return .production }
        return configurationError == nil ? .isolatedTest(targetVersion: "0.1.4") : .disabledTest
    }
    var downloadPage: URL {
        URL(string: updateChannel.repository + (isUpdateTest ? "/releases/tag/" + updateChannel.tagPrefix + "0.1.4" : "/releases"))!
    }

    static func load(info: [String: Any], bundleIdentifier: String?) -> AppRuntimeProfile {
        let hasMarker = info["ShanchuanUpdateTest"] != nil || info["ShanchuanUpdateTestTargetVersion"] != nil
        guard hasMarker || bundleIdentifier == testBundleIdentifier else { return .production }
        let error: String?
        if bundleIdentifier != testBundleIdentifier { error = L10n.text("测试构建的应用标识不匹配，更新已停用。") }
        else if info["ShanchuanUpdateTest"] as? Bool != true { error = L10n.text("测试构建缺少测试通道标记，更新已停用。") }
        else if info["ShanchuanUpdateTestTargetVersion"] as? String != "0.1.4" { error = L10n.text("测试构建仅支持目标 0.1.4，更新已停用。") }
        else { error = nil }
        return AppRuntimeProfile(isUpdateTest: true, configurationError: error)
    }
}
