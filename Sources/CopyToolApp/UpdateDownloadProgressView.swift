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

/// One primary action per stage; background work never presents an installation prompt.
struct UpdateStatusPanel: View {
    @ObservedObject private var appLanguage = AppLanguageStore.shared
    @ObservedObject var updates: UpdateCoordinator
    var enabled = true
    private var title: String {
        if updates.waitingForInstallation { return L10n.text("正在准备更新…") }
        if updates.isChecking { return L10n.text(updates.downloadProgress == nil ? "正在检查更新…" : updates.downloadProgress?.isVerifying == true ? "正在校验更新…" : "正在下载更新…") }
        if updates.canInstall { return L10n.text("更新已就绪") }
        if updates.hasCheckFailed { return L10n.text("更新检查失败") }
        return updates.status
    }
    var body: some View {
        let _ = appLanguage.language
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Image(systemName: updates.canInstall ? "arrow.down.circle.fill" : updates.hasCheckFailed ? "exclamationmark.triangle.fill" : "arrow.triangle.2.circlepath")
                    .foregroundStyle(updates.canInstall ? Color.accentColor : updates.hasCheckFailed ? Color.orange : Color.secondary)
                Text(title).font(.caption).fontWeight(.medium)
                Spacer(minLength: 0)
            }
            Text(L10n.text("版本 ") + updates.displayedVersion).font(.caption2).foregroundStyle(.secondary)
            if let progress = updates.downloadProgress {
                UpdateDownloadProgressView(progress: progress)
            } else if updates.isChecking || updates.waitingForInstallation {
                ProgressView().progressViewStyle(.linear)
            }
            if updates.canInstall {
                UpdateInstallReadyView(version: updates.candidateVersion ?? "", releaseNotes: updates.releaseNotes) {
                    updates.requestInstall()
                }.disabled(!enabled)
            } else {
                Button {
                    if updates.hasCheckFailed { updates.retry() } else { updates.check() }
                } label: {
                    Text(updates.waitingForInstallation ? L10n.text("正在准备更新…") :
                         updates.hasCheckFailed ? L10n.text("重试") : updates.checkButtonTitle)
                        .frame(maxWidth: .infinity)
                }.controlSize(.small).disabled(!enabled || !updates.canCheck)
                    .accessibilityIdentifier("update-primary-action")
            }
            DisclosureGroup(L10n.text("更新详情")) {
                ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    Text(updates.status).textSelection(.enabled)
                    if let checked = updates.lastCheckCompletedAt { Text(L10n.text("最近检查：") + L10n.date(checked)) }
                    if !updates.relayStatus.isEmpty { Text(updates.relayStatus) }
                    if updates.canInstall {
                        Button(L10n.text("重新检查更新")) { updates.check() }
                            .buttonStyle(.borderless).disabled(!enabled || !updates.canCheck)
                    }
                }.font(.caption2).foregroundStyle(.secondary).padding(.top, 4)
                }.frame(maxHeight: 140)
            }.font(.caption2)
        }.padding(10).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
            .accessibilityIdentifier("update-status-panel")
    }
}
