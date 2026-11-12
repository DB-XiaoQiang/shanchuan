import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CopyToolCore

struct RootView: View {
    @ObservedObject var model: AppModel
    @State private var page = "history"
    @State private var showClear = false
    @State private var dropped = false
    var body: some View {
        NavigationSplitView {
            List(selection: $page) {
                Label("剪贴板记录", systemImage: "doc.on.clipboard").tag("history")
                Label("传输日志", systemImage: "arrow.up.arrow.down").tag("logs")
                Label("使用说明", systemImage: "info.circle").tag("about")
            }.navigationSplitViewColumnWidth(min: 150, ideal: 175)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    AppLogo(size: 38)
                    Text("闪传").font(.headline)
                }
                Text("本机历史 · 快捷键投递").font(.caption).foregroundStyle(.secondary)
                if #available(macOS 14.0, *) { SettingsLink { Text("配置中心…") } }
                else { Button("配置中心…") { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) } }
            }.padding()
        } detail: {
            VStack(spacing: 0) {
                if page == "history" { history }
                else if page == "logs" { TransferLogsView(model: model) }
                else { about }
                Divider()
                HStack {
                    Circle().fill(model.preferences.host.isEmpty ? Color.orange : Color.green).frame(width: 7, height: 7)
                    Text(model.privacy ? "隐私模式已开启" : model.message).font(.caption).lineLimit(1)
                    Spacer()
                    Text("\(model.entries.count) 条记录").font(.caption).foregroundStyle(.secondary)
                }.padding(10)
            }
            .navigationTitle("闪传")
            .toolbar {
                ToolbarItemGroup {
                    Label("仅快捷键发送", systemImage: "keyboard").help("\(model.preferences.shortcuts.copy.displayName) 复制、记录并发送；Command+C 不记录、不上传")
                    Button { model.chooseFiles() } label: { Label("添加文件", systemImage: "plus") }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: FailureNotifications.openLogs)) { _ in page = "logs" }
        .onDrop(of: [UTType.fileURL], isTargeted: $dropped) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in if let url { Task { @MainActor in model.addFiles([url], automatic: false) } } }
            }
            return !providers.isEmpty
        }
        .overlay { if dropped { RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, lineWidth: 4).padding(8).allowsHitTesting(false) } }
        .alert("清空本应用所有历史？", isPresented: $showClear) {
            Button("取消", role: .cancel) {}
            Button("清空记录", role: .destructive) { model.clearHistory() }
        } message: { Text("会删除本应用保存的文本和图片记录。原始文件不会删除。") }
    }
    private var history: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("快速搜索记录内容…", text: $model.search).textFieldStyle(.roundedBorder)
                Picker("类型", selection: $model.filter) {
                    Text("所有类型").tag(HistoryEntry.Kind?.none)
                    Text("文本").tag(HistoryEntry.Kind?.some(.text))
                    Text("文件").tag(HistoryEntry.Kind?.some(.file))
                    Text("图片").tag(HistoryEntry.Kind?.some(.image))
                }.labelsHidden().frame(width: 100)
                Button { model.privacy.toggle() } label: { Image(systemName: model.privacy ? "eye.slash" : "eye") }.help("隐私模式")
                Button { showClear = true } label: { Image(systemName: "trash") }.help("清空记录")
            }.padding(14)
            if !model.activeTransfer.isEmpty {
                HStack {
                    VStack(alignment: .leading) {
                        Text("发送：\(model.privacy ? "文件传输" : model.activeTransfer)").lineLimit(1)
                        if let value = model.transferSnapshot.fraction {
                            ProgressView(value: value)
                        } else { ProgressView().controlSize(.small) }
                    }
                    Text("\(model.transferMenuTitle) · 等待 \(model.queued)").font(.caption)
                    if model.transferSnapshot.totalBytes > 0 {
                        Text("\(ByteCountFormatter.string(fromByteCount: model.transferSnapshot.uploadedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: model.transferSnapshot.totalBytes, countStyle: .file))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("取消") { model.cancelAll() }
                }.padding(.horizontal, 14).padding(.bottom, 10)
            }
            if model.visibleEntries.isEmpty {
                Spacer()
                Image(systemName: "doc.on.clipboard").font(.system(size: 42)).foregroundStyle(.secondary)
                Text(model.search.isEmpty ? "\(model.preferences.shortcuts.copy.displayName) 复制并发送到内网" : "没有匹配记录").font(.headline).padding(.top)
                Text("Command+C 不记录、不上传；也可以拖入文件或文件夹发送。") .foregroundStyle(.secondary).padding(.top, 4)
                Spacer()
            } else {
                HSplitView {
                    List(selection: $model.selected) {
                        ForEach(model.visibleEntries) { entry in
                            HistoryRow(entry: entry, privacy: model.privacy).tag(entry.id)
                                .onTapGesture(count: 2) { model.resend(entry) }
                                .contextMenu {
                                    Button("恢复到剪贴板") { model.restore(entry) }
                                    Button("重新发送") { model.resend(entry) }
                                    if let path = entry.paths.first { Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } }
                                    Divider()
                                    Button("删除记录", role: .destructive) { model.delete(entry) }
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
                HStack { Text("记录详情").font(.headline); Spacer(); Text(entry.status).font(.caption).foregroundStyle(.secondary) }
                Text(entry.date.formatted()).font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    if model.privacy { Text("内容已隐藏").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
                    else if entry.kind == .image, let path = entry.paths.first, let image = NSImage(contentsOfFile: path) { Image(nsImage: image).resizable().scaledToFit() }
                    else { Text(entry.kind == .text ? entry.content : entry.paths.joined(separator: "\n")).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                }
                HStack {
                    Button("恢复剪贴板") { model.restore(entry) }
                    Button("重新发送") { model.resend(entry) }.buttonStyle(.borderedProminent)
                }
            }.padding(16)
        } else { Text("选择一条记录查看详情").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
    }
    private var about: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    AppLogo(size: 80)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("闪传").font(.largeTitle)
                        Text("0.1.0").foregroundStyle(.secondary)
                    }
                }
                Text("根据本机应用的界面与静态证据，独立实现的 macOS 剪贴板与 FTP 投递工具。")
                GroupBox("主要功能") {
                    Text("• 自定义复制发送文本、图片与文件\n• 发送记录持久化、搜索、类型筛选与隐私显示\n• 拖拽文件/文件夹，目录自动 ZIP 打包\n• FTP 串行上传、进度、取消及历史重发\n• 菜单栏常驻、开机启动、钥匙串密码保存") .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                GroupBox("使用方式") {
                    Text("先在配置中心设置 FTP 与自定义快捷键。自定义复制执行复制、记录并发送到内网，自定义粘贴只在当前应用粘贴。Command+C 等普通复制只改变系统剪贴板，既不记录也不上传。拖入或添加文件、手动“重新发送”也可投递。“开启历史记录”只控制明确发送内容是否留记录。恢复剪贴板不会新增记录或发送。关闭主窗口后可通过菜单栏重新显示。") .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                GroupBox("兼容范围") {
                    Text("文本、文件与文件夹已通过原内网接收端验证；加密 Office 实际解密与自动更新未验证。原 FTP 配置可在配置中心显式迁移。本程序使用独立数据目录，不读取原版历史或授权。") .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                Button("打开本地数据目录") { NSWorkspace.shared.open(model.root) }
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
                Text(privacy ? "内容已隐藏" : entry.title).lineLimit(2)
                HStack { Text(entry.date.formatted(date: .abbreviated, time: .shortened)); Spacer(); Text(entry.status) }.font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 6)
    }
}
