import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CopyToolCore

struct RootView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updates: UpdateCoordinator
    @ObservedObject var navigation: AppNavigation
    @ObservedObject var settings: SettingsPageSession
    @Environment(\.openWindow) private var openWindow
    @State private var showClear = false
    @State private var dropped = false
    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { navigation.page }, set: { navigation.select($0) })) {
                Label(L10n.text("剪贴板记录"), systemImage: "doc.on.clipboard").tag(AppNavigation.Page.history)
                Label(L10n.text("传输日志"), systemImage: "arrow.up.arrow.down").tag(AppNavigation.Page.logs)
                Label(L10n.text("配置中心"), systemImage: "gearshape").tag(AppNavigation.Page.settings)
                Label(L10n.text("使用说明"), systemImage: "info.circle").tag(AppNavigation.Page.about)
            }.navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 300)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    AppLogo(size: 38)
                    Text(model.runtimeProfile.applicationName).font(.headline)
                }
                Text(model.runtimeProfile.isUpdateTest ? L10n.text("独立测试通道 · 不连接 FTP") : L10n.text("本机历史 · 快捷键投递"))
                    .font(.caption).foregroundStyle(.secondary)
                if let error = model.runtimeProfile.configurationError { Text(error).font(.caption).foregroundStyle(.red) }
                Divider()
                Text(L10n.text("版本 ") + updates.displayedVersion).font(.caption).foregroundStyle(.secondary)
                Text(updates.status).font(.caption).textSelection(.enabled)
                if let checkedAt = updates.lastCheckCompletedAt {
                    Text(L10n.text("最近检查：") + L10n.date(checkedAt))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if !updates.relayStatus.isEmpty { Text(updates.relayStatus).font(.caption2).foregroundStyle(.secondary) }
                ViewThatFits(in: .horizontal) {
                    HStack { checkUpdatesButton; retryUpdateButton }.fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading) { checkUpdatesButton; retryUpdateButton }
                }.controlSize(.small)
                Link(model.runtimeProfile.isUpdateTest ? L10n.text("测试通道发布页") : L10n.text("测试版下载"), destination: model.runtimeProfile.downloadPage).font(.caption)
                    .help(L10n.text("打开 GitHub 安装包下载页，测试版需要手动安装"))
                if updates.canInstall {
                    Button(L10n.text("更新至 ") + (updates.candidateVersion ?? "")) { updates.requestInstall() }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .disabled(!model.runtimeProfile.updatesEnabled)
                }
            }.padding()
        } detail: {
            VStack(spacing: 0) {
                if model.runtimeProfile.isUpdateTest {
                    Text(L10n.text("独立更新测试：仅用于 0.1.3 → 0.1.4。设置、历史和更新缓存与正式应用分开；普通传输、剪贴板操作、全局快捷键和系统通知均停用。"))
                        .font(.callout).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    Divider()
                }
                switch navigation.page {
                case .history: history
                case .logs: TransferLogsView(model: model)
                case .settings: SettingsView(model: model, session: settings).padding(20).accessibilityIdentifier("settings-page")
                case .about: about
                }
                Divider()
                HStack {
                    Circle().fill(model.preferences.host.isEmpty ? Color.orange : Color.green).frame(width: 7, height: 7)
                    Text(model.privacy ? L10n.text("隐私模式已开启") : model.message).font(.caption).lineLimit(1)
                    Spacer()
                    Text(L10n.format("%@ 条记录", String(describing: model.entries.count))).font(.caption).foregroundStyle(.secondary)
                }.padding(10)
            }
            .navigationTitle(navigation.page.title)
            .toolbar {
                ToolbarItemGroup {
                    if navigation.page == .history {
                        Label(L10n.text("仅快捷键发送"), systemImage: "keyboard").help(L10n.format("%@ 复制、记录并发送；Command+C 不记录、不上传", String(describing: model.preferences.shortcuts.copy.displayName)))
                        Button { model.chooseFiles() } label: { Label(L10n.text("添加文件"), systemImage: "plus") }
                            .disabled(!model.allowsBusinessTransfers)
                    }
                }
            }
        }
        .onAppear {
            let open = openWindow
            navigation.showMainWindow = { open(id: "main") }
        }
        .onReceive(NotificationCenter.default.publisher(for: FailureNotifications.openLogs)) { _ in navigation.select(.logs) }
        .onDrop(of: [UTType.fileURL], isTargeted: $dropped) { providers in
            guard model.allowsBusinessTransfers, navigation.acceptsFileDrop else { return false }
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in if let url { Task { @MainActor in model.addFiles([url], automatic: false) } } }
            }
            return !providers.isEmpty
        }
        .overlay { if dropped && navigation.acceptsFileDrop { RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, lineWidth: 4).padding(8).allowsHitTesting(false) } }
        .alert(L10n.text("清空本应用所有历史？"), isPresented: $showClear) {
            Button(L10n.text("取消"), role: .cancel) {}
            Button(L10n.text("清空记录"), role: .destructive) { model.clearHistory() }
        } message: { Text(L10n.text("会删除本应用保存的文本和图片记录。原始文件不会删除。")) }
    }
    private var checkUpdatesButton: some View {
        Button(updates.isChecking ? L10n.text("检查中…") : L10n.text("检查更新")) { updates.check() }
            .disabled(!model.runtimeProfile.updatesEnabled || !updates.canCheck)
    }
    private var retryUpdateButton: some View {
        Button(L10n.text("重试")) { updates.retry() }
            .disabled(!model.runtimeProfile.updatesEnabled || !updates.canCheck || updates.isRelaying)
    }
    private var history: some View {
        VStack(spacing: 0) {
            HStack {
                TextField(L10n.text("快速搜索记录内容…"), text: $model.search).textFieldStyle(.roundedBorder)
                Picker(L10n.text("类型"), selection: $model.filter) {
                    Text(L10n.text("所有类型")).tag(HistoryEntry.Kind?.none)
                    Text(L10n.text("文本")).tag(HistoryEntry.Kind?.some(.text))
                    Text(L10n.text("文件")).tag(HistoryEntry.Kind?.some(.file))
                    Text(L10n.text("图片")).tag(HistoryEntry.Kind?.some(.image))
                }.labelsHidden().frame(width: 100)
                Button { model.privacy.toggle() } label: { Image(systemName: model.privacy ? "eye.slash" : "eye") }.help(L10n.text("隐私模式"))
                Button { showClear = true } label: { Image(systemName: "trash") }.help(L10n.text("清空记录"))
            }.padding(14)
            if !model.activeTransfer.isEmpty {
                HStack {
                    VStack(alignment: .leading) {
                        Text(L10n.format("发送：%@", String(describing: model.privacy ? L10n.text("文件传输") : model.activeTransfer))).lineLimit(1)
                        if let value = model.transferSnapshot.fraction {
                            ProgressView(value: value)
                        } else { ProgressView().controlSize(.small) }
                    }
                    Text(L10n.format("%@ · 等待 %@", String(describing: model.transferMenuTitle), String(describing: model.queued))).font(.caption)
                    if model.transferSnapshot.totalBytes > 0 {
                        Text("\(ByteCountFormatter.string(fromByteCount: model.transferSnapshot.uploadedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: model.transferSnapshot.totalBytes, countStyle: .file))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button(L10n.text("取消")) { model.cancelAll() }
                }.padding(.horizontal, 14).padding(.bottom, 10)
            }
            if model.visibleEntries.isEmpty {
                Spacer()
                Image(systemName: "doc.on.clipboard").font(.system(size: 42)).foregroundStyle(.secondary)
                Text(model.runtimeProfile.isUpdateTest ? L10n.text("请从左下角检查测试更新") : (model.search.isEmpty ? L10n.format("%@ 复制并发送到内网", String(describing: model.preferences.shortcuts.copy.displayName)) : L10n.text("没有匹配记录"))).font(.headline).padding(.top)
                Text(model.runtimeProfile.isUpdateTest ? L10n.text("本窗口不读取正式配置或 FTP 密码，也不会发送任何文件。") : L10n.text("Command+C 不记录、不上传；也可以拖入文件或文件夹发送。")) .foregroundStyle(.secondary).padding(.top, 4)
                Spacer()
            } else {
                HSplitView {
                    List(selection: $model.selected) {
                        ForEach(model.visibleEntries) { entry in
                            HistoryRow(entry: entry, privacy: model.privacy).tag(entry.id)
                                .onTapGesture(count: 2) { model.resend(entry) }
                                .contextMenu {
                                    Button(L10n.text("恢复到剪贴板")) { model.restore(entry) }.disabled(!model.allowsBusinessTransfers)
                                    Button(L10n.text("重新发送")) { model.resend(entry) }.disabled(!model.allowsBusinessTransfers)
                                    if let path = entry.paths.first { Button(L10n.text("在 Finder 中显示")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } }
                                    Divider()
                                    Button(L10n.text("删除记录"), role: .destructive) { model.delete(entry) }
                                }
                        }
                    }.frame(minWidth: 260)
                    detail.frame(minWidth: 220)
                }
            }
        }
    }
    @ViewBuilder private var detail: some View {
        if let entry = model.selectedEntry {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text(L10n.text("记录详情")).font(.headline); Spacer(); Text(L10n.text(entry.status)).font(.caption).foregroundStyle(.secondary) }
                Text(L10n.date(entry.date)).font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    if model.privacy { Text(L10n.text("内容已隐藏")).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
                    else if entry.kind == .image, let path = entry.paths.first, let image = NSImage(contentsOfFile: path) { Image(nsImage: image).resizable().scaledToFit() }
                    else { Text(entry.kind == .text ? entry.content : entry.paths.joined(separator: "\n")).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                }
                HStack {
                    Button(L10n.text("恢复剪贴板")) { model.restore(entry) }.disabled(!model.allowsBusinessTransfers)
                    Button(L10n.text("重新发送")) { model.resend(entry) }.buttonStyle(.borderedProminent).disabled(!model.allowsBusinessTransfers)
                }
            }.padding(16)
        } else { Text(L10n.text("选择一条记录查看详情")).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
    }
    private var about: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    AppLogo(size: 80)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.runtimeProfile.applicationName).font(.largeTitle)
                        Text(updates.displayedVersion).foregroundStyle(.secondary)
                    }
                }
                Text(L10n.text("根据本机应用的界面与静态证据，独立实现的 macOS 剪贴板与 FTP 投递工具。"))
                GroupBox(L10n.text("主要功能")) {
                    Text(L10n.text("• 自定义复制发送文本、图片与文件\n• 发送记录持久化、搜索、类型筛选与隐私显示\n• 拖拽文件/文件夹，目录自动 ZIP 打包\n• FTP 串行上传、进度、取消及历史重发\n• 菜单栏常驻、开机启动、钥匙串密码保存")) .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                GroupBox(L10n.text("使用方式")) {
                    Text(L10n.text("先在配置中心设置 FTP 与自定义快捷键。自定义复制执行复制、记录并发送到内网，自定义粘贴只在当前应用粘贴。Command+C 等普通复制只改变系统剪贴板，既不记录也不上传。拖入或添加文件、手动“重新发送”也可投递。“开启历史记录”只控制明确发送内容是否留记录。恢复剪贴板不会新增记录或发送。关闭主窗口后可通过菜单栏重新显示。")) .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                GroupBox(L10n.text("兼容范围")) {
                    Text(L10n.text("文本、文件与文件夹已通过原内网接收端验证；加密 Office 实际解密仍需实际环境验证；应用自动更新需要签名正式版本，首次需手动安装。原 FTP 配置可在配置中心显式迁移。本程序使用独立数据目录，不读取原版历史或授权。")) .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                Button(L10n.text("打开本地数据目录")) { NSWorkspace.shared.open(model.root) }
            }.padding(24)
        }
    }
}
struct HistoryRow: View {
    let entry: HistoryEntry
    let privacy: Bool
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.kind == .text ? "text.alignleft" : (entry.kind == .image ? "photo" : "doc"))
                .foregroundStyle(.blue).frame(width: 22).padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                Text(privacy ? L10n.text("内容已隐藏") : entry.title).lineLimit(2)
                HStack { Text(L10n.date(entry.date, time: .shortened)); Spacer(); Text(L10n.text(entry.status)) }.font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 6)
    }
}
