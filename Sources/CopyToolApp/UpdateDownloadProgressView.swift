import SwiftUI
import CopyToolCore

struct UpdateDownloadProgress: Equatable, Sendable {
    let version: String
    let assetName: String
    let downloadedBytes: Int64
    let totalBytes: Int64
    let isVerifying: Bool
    var fraction: Double { totalBytes > 0 ? min(1, max(0, Double(downloadedBytes) / Double(totalBytes))) : 0 }
    var percentage: String { String(Int(fraction * 100)) + "%" }
    var amount: String {
        L10n.format("已下载 %@ / %@", Self.bytes(max(0, downloadedBytes)), Self.bytes(max(0, totalBytes)))
    }
    private static func bytes(_ value: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var amount = Double(value), index = 0
        while amount >= 1000 && index < units.count - 1 { amount /= 1000; index += 1 }
        return String(format: index == 0 ? "%.0f %@" : "%.1f %@", locale: Locale(identifier: "en_US_POSIX"), amount, units[index])
    }
}

struct UpdateDownloadProgressView: View {
    @ObservedObject private var appLanguage = AppLanguageStore.shared
    let progress: UpdateDownloadProgress
    var body: some View {
        let _ = appLanguage.language
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(L10n.format("下载版本 %@", progress.version))
                Spacer(minLength: 4)
                Text(progress.percentage).monospacedDigit()
            }.font(.caption)
            ProgressView(value: progress.fraction).progressViewStyle(.linear)
                .accessibilityLabel(L10n.text("更新下载进度"))
                .accessibilityValue(progress.percentage)
            Text(progress.amount).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
            if progress.isVerifying {
                Text(L10n.text("正在校验更新，校验通过后即可安装")).font(.caption2).foregroundStyle(.secondary)
            }
        }.accessibilityIdentifier("update-download-progress")
    }
}

struct UpdateInstallReadyView: View {
    @ObservedObject private var appLanguage = AppLanguageStore.shared
    let version: String
    let releaseNotes: String
    let action: () -> Void
    var body: some View {
        let _ = appLanguage.language
        VStack(alignment: .leading, spacing: 7) {
            Text(L10n.format("更新至 %@，点击后安装并重启。", version))
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup(L10n.text("更新说明")) {
                ScrollView { Text(releaseNotes).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 140)
            }.font(.caption)
            Button(action: action) {
                Text(L10n.text("更新并重启")).frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent).controlSize(.small)
                .help(L10n.text("点击后等待传输完成，再安装此版本并重启应用。"))
                .accessibilityIdentifier("update-install-and-restart")
        }
    }
}
