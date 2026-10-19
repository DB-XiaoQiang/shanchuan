import SwiftUI
import ServiceManagement
import CopyToolCore

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @StateObject private var autosave = SettingsAutosaveStore()
    @StateObject private var connectionTest = FTPConnectionTestStore()
    @State private var migrationError = ""
    @State private var autostart = SMAppService.mainApp.status == .enabled
    @State private var autostartError = ""
    @StateObject private var windowAccess = SettingsWindowAccess()
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("配置中心").font(.title2)
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
                Section("本地行为") {
                    Stepper("历史保留：\(autosave.draft.ttlDays) 天", value: $autosave.draft.ttlDays, in: 1...3650)
                    Toggle("开启历史记录", isOn: $autosave.draft.historyEnabled)
                    Toggle("重发时恢复到本地剪贴板", isOn: $autosave.draft.restoreOnResend)
                    Toggle("同步完成时通知", isOn: $autosave.draft.notificationsEnabled)

                    Toggle("登录后自动启动", isOn: $autostart).onChange(of: autostart) { enabled in
                        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; autostartError = "" }
                        catch { autostartError = error.localizedDescription; autostart = SMAppService.mainApp.status == .enabled }
                    }
                }
                Section("传输提示") {
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
                Text("FTP 连接仅在测试或发送时发起").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(autosave.status.text).font(.caption)
                    .foregroundStyle(statusColor)
            }
        }
        .onAppear { [model, autosave, connectionTest, windowAccess] in
            autosave.connect(current: { [weak model] in
                (model?.preferences ?? AppPreferences(), model?.password ?? "")
            }, save: { [weak model] values, password in
                guard let model else { return "设置尚未就绪" }
                let shouldRequestNotifications = values.notificationsEnabled && !model.preferences.notificationsEnabled
                guard model.saveSettings(preferences: values, password: password) else { return model.settingsError }
                if shouldRequestNotifications { model.requestNotifications(true) }
                return nil
            })
            windowAccess.willClose = { [weak autosave, weak connectionTest] in
                autosave?.flush()
                connectionTest?.cancel()
            }
            model.flushSettings = { [weak windowAccess, weak autosave, weak connectionTest] in
                windowAccess?.window?.makeFirstResponder(nil)
                autosave?.flush()
                connectionTest?.cancel()
            }
        }
        .onChange(of: autosave.draft) { _ in migrationError = ""; autosave.schedule() }
        .onChange(of: autosave.secret) { _ in migrationError = ""; autosave.schedule() }
        .onChange(of: autosave.portText) { _ in migrationError = ""; autosave.schedule() }
        .onChange(of: connectionInput) { input in connectionTest.inputChanged(input) }
        .onDisappear { windowAccess.flushBeforeClose() }
        .background(SettingsWindowReader(access: windowAccess).frame(width: 0, height: 0))
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
