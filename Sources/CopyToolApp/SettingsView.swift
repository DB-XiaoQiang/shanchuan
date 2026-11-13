import SwiftUI
import ServiceManagement
import CopyToolCore

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var autosave: SettingsAutosaveStore
    @ObservedObject private var connectionTest: FTPConnectionTestStore
    @ObservedObject private var failureNotifications = FailureNotifications.shared
    @State private var migrationError = ""
    @State private var autostart = SMAppService.mainApp.status == .enabled
    @State private var autostartError = ""
    @ObservedObject private var windowAccess: SettingsWindowAccess
    let session: SettingsPageSession

    init(model: AppModel, session: SettingsPageSession) {
        self.model = model
        self.session = session
        autosave = session.autosave
        connectionTest = session.connectionTest
        windowAccess = session.windowAccess
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("修改后自动保存；配置未保存时会留在此页面，修正后再切换。")
                .font(.caption).foregroundStyle(.secondary)
            Form {
                Section("FTP 投递") {
                    HStack {
                        TextField("服务器主机名 / IP", text: $autosave.draft.host)
                        Button { connectionTest.test(input: connectionInput) } label: {
                            HStack(spacing: 5) {
                                if connectionTest.isTesting {
                                    ProgressView().controlSize(.small).frame(width: 14, height: 14)
                                }
                                Text(connectionTest.isTesting ? "测试中…" : "测试连接")
                            }
                        }
                        .disabled(connectionTest.isTesting)
                    }
                    TextField("端口", text: $autosave.portText)
                    TextField("目标目录", text: $autosave.draft.directory)
                    TextField("用户名", text: $autosave.draft.username)
                    SecureField("密码", text: $autosave.secret)
                    VStack(alignment: .leading, spacing: 5) {
                        if connectionTest.state != .idle {
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: connectionResultIcon)
                                Text(connectionTest.state.text).fixedSize(horizontal: false, vertical: true)
                                if connectionTest.isTesting {
                                    Spacer()
                                    Button("取消") { connectionTest.cancel() }
                                }
                            }
                            .foregroundStyle(connectionResultColor)
                        }
                        Text("验证 FTP 登录和目标目录，不上传文件或检查写入权限。")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    TextField("控制文件名", text: $autosave.draft.textRemoteName)
                    Toggle("按原协议路由加密标记文件", isOn: $autosave.draft.autoDecrypt)
                    TextField("解密目录前缀", text: $autosave.draft.decryptPrefix)
                }
                Section("目录排除规则") {
                    DirectoryExclusionSettingsView(rules: $autosave.draft.directoryExclusionRules,
                        saveStatus: autosave.status, onEditingFinished: { autosave.flush() })
                }
                Section("本地行为") {
                    Stepper("历史保留：\(autosave.draft.ttlDays) 天", value: $autosave.draft.ttlDays, in: 1...3650)
                    Toggle("开启历史记录", isOn: $autosave.draft.historyEnabled)
                    Toggle("重发时恢复到本地剪贴板", isOn: $autosave.draft.restoreOnResend)
                    Toggle("登录后自动启动", isOn: $autostart).onChange(of: autostart) { enabled in
                        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; autostartError = "" }
                        catch { autostartError = error.localizedDescription; autostart = SMAppService.mainApp.status == .enabled }
                    }
                }
                Section("传输提示") {
                    Text("快捷键未发送或上传失败时显示系统通知，8 秒内合并重复提醒。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(failureNotifications.status).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("允许通知 / 打开系统设置") { failureNotifications.enable() }
                        Button("测试失败通知") {
                            failureNotifications.send(SendFailureNotice(title: "闪传失败通知测试", body: "这是一条测试提醒，未上传任何数据。"))
                        }
                    }
                    Toggle("上传时显示右上角进度卡片", isOn: $autosave.draft.showTransferProgress)
                    Button("预览进度卡片") { model.previewTransferProgress?() }
                    Text("显示准备状态、上传百分比和已上传大小；关闭卡片不会取消上传。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("复制发送 / 粘贴快捷键") { ShortcutSettingsView(model: model) }
            }.formStyle(.grouped)
            if !migrationError.isEmpty { Text(migrationError).foregroundStyle(.red) }
            if !autostartError.isEmpty { Text("开机启动：\(autostartError)").foregroundStyle(.red) }
            HStack {
                Button("从原应用迁移 FTP") {
                    autosave.flush()
                    model.migrateOriginalFTP()
                    migrationError = model.settingsError
                    if migrationError.isEmpty { autosave.reload() }
                }
                Button("撤销未保存修改") { autosave.reload(); migrationError = "" }
                    .disabled(!canDiscardChanges)
                Text("测试连接不上传文件").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(autosave.status.text).font(.caption)
                    .foregroundStyle(statusColor)
            }
        }
        .onAppear { session.connect(model: model) }
        .onChange(of: autosave.draft) { _ in migrationError = ""; autosave.schedule() }
        .onChange(of: autosave.secret) { _ in migrationError = ""; autosave.schedule() }
        .onChange(of: autosave.portText) { _ in migrationError = ""; autosave.schedule() }
        .onChange(of: connectionInput) { input in connectionTest.inputChanged(input) }
        .onDisappear { windowAccess.flushBeforeClose() }
        .background(SettingsWindowReader(access: windowAccess).frame(width: 0, height: 0))
    }

    private var canDiscardChanges: Bool {
        switch autosave.status {
        case .pending, .failed: return true
        case .ready, .saved: return false
        }
    }

    private var statusColor: Color {
        if case .failed = autosave.status { return .red }
        return .secondary
    }

    private var connectionInput: FTPConnectionTestInput {
        FTPConnectionTestInput(host: autosave.draft.host, portText: autosave.portText,
            username: autosave.draft.username, password: autosave.secret, directory: autosave.draft.directory)
    }

    private var connectionResultColor: Color {
        switch connectionTest.state {
        case .success: return .green
        case .failed: return .red
        default: return .secondary
        }
    }

    private var connectionResultIcon: String {
        switch connectionTest.state {
        case .success: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        default: return "network"
        }
    }
}
