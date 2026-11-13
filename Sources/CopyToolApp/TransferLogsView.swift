import SwiftUI
import CopyToolCore

struct TransferLogsView: View {
    @ObservedObject var model: AppModel
    @State private var search = ""

    private var visibleLogs: [TransferLogEntry] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.transferLogs }
        return model.transferLogs.filter {
            (!model.privacy && $0.message.localizedCaseInsensitiveContains(query))
                || TransferLogRow.levelTitle($0.level).localizedCaseInsensitiveContains(query)
                || TransferLogRow.dateText($0.date).localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.text("传输日志")).font(.title2)
                if model.privacy {
                    Label(L10n.text("隐私模式已开启"), systemImage: "eye.slash")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(search.isEmpty ? L10n.format("%@ 条日志", String(describing: model.transferLogs.count)) : L10n.format("%@ / %@ 条日志", String(describing: visibleLogs.count), String(describing: model.transferLogs.count)))
                    .font(.caption).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.text("日志保存在本机，重新打开应用后可继续查看。最新日志显示在最上方。"))
                    .font(.caption).foregroundStyle(.secondary)
                if !model.privacy {
                    Text(model.transferLogFile.path)
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(model.transferLogFile.path)
                }
            }

            if !model.logPersistenceError.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.text("日志文件读写异常")).fontWeight(.semibold)
                        Text(model.privacy ? L10n.text("日志无法正常读取或保存，关闭隐私模式后可查看详细原因。") : model.logPersistenceError)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 0)
                }
                .font(.callout).foregroundStyle(.red)
                .padding(10)
                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }

            TextField(model.privacy ? L10n.text("搜索日志等级或日期…") : L10n.text("搜索日志内容、等级或日期…"), text: $search)
                .textFieldStyle(.roundedBorder)

            if model.transferLogs.isEmpty {
                emptyState(title: L10n.text("尚无传输日志"), detail: L10n.text("使用自定义复制快捷键、添加文件或手动重新发送后，可在这里查看过程和结果。"))
            } else if visibleLogs.isEmpty {
                emptyState(title: L10n.text("没有匹配的日志"), detail: L10n.text("请尝试其他关键词，或清空搜索内容。"))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(visibleLogs) { entry in
                            TransferLogRow(entry: entry, privacy: model.privacy)
                            Divider()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Button(L10n.text("发送文本、文件和文件夹验证样例")) { model.sendValidationSamples() }
                    .disabled(!model.activeTransfer.isEmpty || model.queued > 0)
                Text(L10n.text("仅点击按钮时发送合成样例到配置的 FTP；接收结果须在内网端核对。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func emptyState(title: String, detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 34)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TransferLogRow: View {
    let entry: TransferLogEntry
    let privacy: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Text(Self.dateText(entry.date))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Label(Self.levelTitle(entry.level), systemImage: levelSymbol)
                    .font(.caption).foregroundStyle(levelColor)
                Spacer(minLength: 0)
            }
            Text(privacy ? L10n.text("日志详情已隐藏") : entry.message)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 12)
    }

    static func levelTitle(_ level: TransferLogEntry.Level) -> String {
        switch level {
        case .info: return L10n.text("信息")
        case .success: return L10n.text("成功")
        case .warning: return L10n.text("提醒")
        case .error: return L10n.text("失败")
        case .cancelled: return L10n.text("已取消")
        }
    }

    static func dateText(_ date: Date) -> String {
        date.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)
            .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits).locale(L10n.language.locale))
    }

    private var levelColor: Color {
        switch entry.level {
        case .info: return .secondary
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        case .cancelled: return .secondary
        }
    }

    private var levelSymbol: String {
        switch entry.level {
        case .info: return "info.circle"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.circle.fill"
        case .cancelled: return "stop.circle"
        }
    }
}
