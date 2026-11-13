import Foundation
import CopyToolCore

/// 测试发行源只由隔离应用显式注入；正式应用始终使用默认正式通道。
struct UpdateChannel: Equatable, Sendable {
    private let testTargetVersion: String?
    static let production = UpdateChannel(testTargetVersion: nil)
    static let disabledTest = UpdateChannel(testTargetVersion: "")

    static func isolatedTest(targetVersion: String = "0.1.4") -> UpdateChannel {
        UpdateChannel(testTargetVersion: targetVersion)
    }

    var isTest: Bool { testTargetVersion != nil }
    var configurationError: String? {
        guard let testTargetVersion else { return nil }
        return testTargetVersion == "0.1.4" ? nil : L10n.text("测试更新目标配置无效；仅允许指定的 0.1.4 测试发行版。")
    }
    var repository: String { "https://github.com/DB-XiaoQiang/shanchuan" }
    var tagPrefix: String { isTest ? "update-test-v" : "v" }
    var expectedManifestChannel: String { isTest ? "test" : "stable" }
    var requiresWindowsAssets: Bool { !isTest }
    var allowsRelay: Bool { !isTest }
    var metadataURL: URL {
        // 无效配置也绝不拼接用户数据或退回正式源；调用方会阻止请求。
        let endpoint = isTest ? "tags/update-test-v0.1.4" : "latest"
        return URL(string: "https://api.github.com/repos/DB-XiaoQiang/shanchuan/releases/" + endpoint)!
    }
    var noReleaseStatus: String {
        isTest ? L10n.text("测试更新尚未发布，请稍后重试") : L10n.text("暂无正式更新；测试版请手动下载")
    }

    func version(fromTag tag: String, draft: Bool, prerelease: Bool) throws -> String {
        if let configurationError { throw UpdateFailure.invalid(configurationError) }
        guard !draft else { throw UpdateFailure.invalid(L10n.text("不接受草稿发行版。")) }
        if let target = testTargetVersion {
            guard prerelease, tag == tagPrefix + target else {
                throw UpdateFailure.invalid(L10n.text("测试通道只接受指定的 update-test-v0.1.4 预发布。"))
            }
            return target
        }
        guard !prerelease, tag.hasPrefix(tagPrefix) else { throw UpdateFailure.invalid(L10n.text("只接受正式发行版。")) }
        let version = String(tag.dropFirst(tagPrefix.count))
        _ = try ReleaseVersion(version)
        return version
    }

    func validateManifestVersion(_ version: String) throws {
        _ = try ReleaseVersion(version)
        if let target = testTargetVersion, version != target {
            throw UpdateFailure.invalid(L10n.text("测试清单版本与指定测试目标不一致。"))
        }
    }

    func assetBase(version: String) -> URL {
        URL(string: repository + "/releases/download/" + tagPrefix + version + "/")!
    }
    func sparkleFeedURL(version: String) -> String {
        assetBase(version: version).appendingPathComponent("appcast.xml").absoluteString
    }
}
