import AppKit
import SwiftUI
import CopyToolCore
import CryptoKit
import Combine

@MainActor final class AppModel: ObservableObject {
    let runtimeProfile: AppRuntimeProfile
    var allowsBusinessTransfers: Bool { runtimeProfile.allowsBusinessTransfers }
    @Published var entries: [HistoryEntry] = []
    @Published var preferences = AppPreferences()
    @Published var password = ""
    @Published var privacy = false
    @Published var search = ""
    @Published var filter: HistoryEntry.Kind?
    @Published var selected: UUID?
    @Published var progress = 0.0
    @Published var activeTransfer = ""
    @Published var queued = 0
    var updateInstallationIsCommitting = false
    @Published var transferSnapshot = TransferProgressSnapshot()
    @Published private var transferTitleSource = L10n.Snapshot.verbatim("")
    var localizedTransferTitle: String { transferTitleSource.rendered }
    var localizedActiveTransfer: String { activeTransfer.isEmpty ? "" : localizedTransferTitle }
    @Published private var transferDetailSource = L10n.Snapshot.verbatim("")
    var localizedTransferDetail: String { transferDetailSource.rendered }
    var previewTransferProgress: (() -> Void)?
    var showTransferProgressCard: (() -> Void)?
    var flushSettings: (() -> Void)?
    @Published private var messageSource = L10n.snapshot("准备就绪 · 尚未配置 FTP")
    var message: String {
        get { messageSource.rendered }
        set { messageSource = .verbatim(newValue) }
    }
    @Published var logs: [String] = []
    @Published private(set) var transferLogs: [TransferLogEntry] = []
    @Published private var logPersistenceErrorSource = L10n.Snapshot.verbatim("")
    var logPersistenceError: String {
        get { logPersistenceErrorSource.rendered }
        set { logPersistenceErrorSource = .verbatim(newValue) }
    }
    @Published private var settingsErrorSource = L10n.Snapshot.verbatim("")
    var settingsErrorSnapshot: L10n.Snapshot { settingsErrorSource }
    var settingsError: String {
        get { settingsErrorSource.rendered }
        set { settingsErrorSource = .verbatim(newValue) }
    }
    @Published private var shortcutSettingsErrorSource = L10n.Snapshot.verbatim("")
    var shortcutSettingsError: String {
        get { shortcutSettingsErrorSource.rendered }
        set { shortcutSettingsErrorSource = .verbatim(newValue) }
    }
    @Published private var shortcutStatusSource = L10n.Snapshot.verbatim("")
    var shortcutStatus: String {
        get { shortcutStatusSource.rendered }
        set { shortcutStatusSource = .verbatim(newValue) }
    }
    @Published var shortcutPermissionGranted = false
    private var shortcutActivationObserver: AnyCancellable?
    private lazy var shortcutService = GlobalCopyPasteShortcuts(
        onStatus: { _ in },
        onCopyReady: { [weak self] count in self?.captureClipboardForShortcut(expectedChangeCount: count) },
        onLocalizedStatus: { [weak self] origin in self?.recordShortcutStatus(origin) }
    )
    let repository: HistoryRepository
    private let logRepository: TransferLogRepository
    private var logFileReadFailed = false
    private let readPassword: () -> String
    private let writePassword: (String) throws -> Void
    private var persistedPassword = ""
    private var failureNoticePolicy = SendFailureNoticePolicy()
    private let sendFailureNotice: (SendFailureNotice) -> Void
    private let worker = DispatchQueue(label: "local.copytool.upload")
    private let transfer = FTPTransfer()
    private var tasks: [(HistoryEntry, AppPreferences, String)] = []
    private var running = false
    private var cancelling = false
    private var activeTransferToken: UUID?
    private var progressFileIndex = -1
    private enum ClipboardSnapshot {
        case files([URL]), image(Data), text(String)
    }
    var visibleEntries: [HistoryEntry] { entries.filter { $0.matches(query: search, kind: filter) } }
    var selectedEntry: HistoryEntry? { entries.first { $0.id == selected } }
    var root: URL { repository.root }
    var transferLogFile: URL { logRepository.file }
    var transferMenuTitle: String {
        switch transferSnapshot.phase {
        case .preparing: return L10n.text("准备中")
        case .cancelling: return L10n.text("正在取消")
        case .publishing: return L10n.text("正在完成")
        case .uploading:
            return transferSnapshot.fraction.map { "\(Int($0 * 100))%" } ?? L10n.text("上传中")
        default: return L10n.text("闪传")
        }
    }

    init(root: URL? = nil, readPassword: (() -> String)? = nil,
         writePassword: ((String) throws -> Void)? = nil,
         sendFailureNotice: ((SendFailureNotice) -> Void)? = nil,
         runtimeProfile: AppRuntimeProfile = .production) {
        self.runtimeProfile = runtimeProfile
        if runtimeProfile.isUpdateTest {
            self.sendFailureNotice = { _ in }
            self.readPassword = { "" }
            self.writePassword = { value in
                guard value.isEmpty else { throw NSError(domain: "ShanchuanUpdateTest", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: L10n.text("独立更新测试不保存 FTP 密码。")] ) }
            }
        } else {
            self.sendFailureNotice = sendFailureNotice ?? (root == nil ? { FailureNotifications.shared.send($0) } : { _ in })
            self.readPassword = readPassword ?? PasswordVault.read
            self.writePassword = writePassword ?? PasswordVault.write
        }
        let base = root ?? runtimeProfile.dataRoot
        logRepository = TransferLogRepository(root: base)
        do { repository = try HistoryRepository(root: base) }
        catch { fatalError(L10n.format("无法建立应用数据目录：%@", String(describing: error.localizedDescription))) }
        do {
            let config = base.appendingPathComponent("preferences.json")
            if FileManager.default.fileExists(atPath: config.path) { preferences = try JSONDecoder().decode(AppPreferences.self, from: Data(contentsOf: config)) }
            entries = repository.prune(try repository.load(), days: preferences.ttlDays)
            try repository.save(entries)
        } catch { messageSource = L10n.snapshotCompose("读取本地数据失败：%@", .literal(error.localizedDescription)) }
        // Password is read only when needed; first launch never requests keychain access.
        if !preferences.host.isEmpty { password = self.readPassword(); messageSource = L10n.snapshot("FTP 已配置 · 等待发送") }
        persistedPassword = password
        loadTransferLogs()
        if runtimeProfile.isUpdateTest {
            // 本地规则等配置仍可编辑，但合成地址永远不会被用于连接。
            if preferences.host.isEmpty { preferences.host = "update-test.invalid" }
            if preferences.username.isEmpty { preferences.username = "update-test" }
            preferences.shortcuts.enabled = false
            messageSource = L10n.snapshot("独立更新测试 · 普通传输、剪贴板与全局快捷键已停用")
            shortcutStatusSource = L10n.snapshot("独立更新测试不注册全局快捷键或申请辅助功能权限。")
            return
        }
        do { try shortcutService.apply(preferences.shortcuts) }
        catch {
            shortcutSettingsError = error.localizedDescription
            logSnapshot(L10n.snapshot("快捷键初始化失败：").appending(shortcutSettingsErrorSource), level: .error)
        }
        refreshShortcutPermission()
        shortcutActivationObserver = NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in Task { @MainActor in self?.refreshShortcutPermission() } }
    }
    func refreshShortcutPermission() {
        guard allowsBusinessTransfers else { return }
        shortcutPermissionGranted = shortcutService.isAccessibilityTrusted
    }
    func recordShortcutStatus(_ status: String) {
        recordShortcutStatus(.verbatim(status))
    }
    private func recordShortcutStatus(_ origin: L10n.Snapshot) {
        shortcutStatusSource = origin
        let status = origin.rendered
        let warning = [L10n.text("未发送"), L10n.text("未执行"), L10n.text("未能"), L10n.text("已取消"), L10n.text("不可"), L10n.text("无法")].contains { status.localizedCaseInsensitiveContains($0) }
        logSnapshot(L10n.snapshot("快捷键：").appending(origin), level: warning ? .warning : .info)
    }
    func openShortcutAccessibilitySettings() { guard allowsBusinessTransfers else { return }; shortcutService.openAccessibilitySettings() }
    func copyInFrontmostApplication() { guard allowsBusinessTransfers else { return }; shortcutService.copyInFrontmostApplication() }
    func pasteInFrontmostApplication() { guard allowsBusinessTransfers else { return }; shortcutService.pasteInFrontmostApplication() }
    func setShortcutRecording(_ active: Bool) {
        guard allowsBusinessTransfers else { return }
        do { try shortcutService.setRecordingShortcut(active) }
        catch { shortcutSettingsError = error.localizedDescription }
    }
    @discardableResult func saveShortcutConfiguration(_ config: CopyPasteShortcuts) -> Bool {
        guard allowsBusinessTransfers else { shortcutSettingsErrorSource = L10n.snapshot("独立更新测试不启用全局快捷键。"); return false }
        shortcutSettingsError = ""
        if let issue = config.validationError { shortcutSettingsErrorSource = L10n.capture(issue); return false }
        let previous = preferences.shortcuts
        do {
            try shortcutService.apply(config)
            var values = preferences
            values.shortcuts = config
            let file = root.appendingPathComponent("preferences.json")
            try JSONEncoder().encode(values).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            preferences = values
            refreshShortcutPermission()
            shortcutStatusSource = config.enabled
                ? L10n.snapshotCompose("已启用：复制 %@，粘贴 %@", .snapshot(config.copy.displaySnapshot), .snapshot(config.paste.displaySnapshot))
                : L10n.snapshot("全局复制 / 粘贴快捷键已关闭")
            return true
        } catch {
            preferences.shortcuts = previous
            try? shortcutService.apply(previous)
            shortcutSettingsError = error.localizedDescription
            return false
        }
    }
    func log(_ text: String, level: TransferLogEntry.Level = .info) {
        logSnapshot(.verbatim(text), level: level)
    }
    func logLocalized(_ source: L10n.Snapshot, level: TransferLogEntry.Level = .info) {
        logSnapshot(source, level: level)
    }
    private func logSnapshot(_ source: L10n.Snapshot, level: TransferLogEntry.Level = .info) {
        let safeSource = source.sanitized(secrets: Set([password, persistedPassword]).filter { !$0.isEmpty }.sorted { $0.count > $1.count },
                                          singleLine: true, maximumLength: 2048)
        let safeText = safeSource.rendered
        messageSource = safeSource
        transferLogs.insert(TransferLogEntry(level: level, message: safeText), at: 0)
        transferLogs = Array(transferLogs.prefix(logRepository.limit))
        updateLogText()
        saveTransferLogs()
        if let notice = failureNoticePolicy.notice(for: safeText, level: level) { sendFailureNotice(notice) }
    }
    private func loadTransferLogs() {
        do {
            if FileManager.default.fileExists(atPath: transferLogFile.path) {
                transferLogs = try logRepository.load()
            } else {
                transferLogs = entries.sorted { $0.date > $1.date }.compactMap { entry in
                    let level: TransferLogEntry.Level
                    switch entry.status {
                    case "已发送": level = .success
                    case "发送失败": level = .error
                    case "已取消": level = .cancelled
                    case "发送中", "等待发送": level = .warning
                    default: return nil
                    }
                    let result = ["发送中", "等待发送"].contains(entry.status)
                        ? L10n.format("当时状态为%@，最终结果未知", String(describing: L10n.text(entry.status))) : L10n.text(entry.status)
                    return TransferLogEntry(id: entry.id, date: entry.date, level: level,
                        message: sanitizedLogMessage(L10n.format("历史记录恢复：%@ · %@（时间为记录创建时间，非上传完成时间）", String(describing: transferSubject(entry)), String(describing: result))))
                }
                transferLogs = Array(transferLogs.prefix(logRepository.limit))
                saveTransferLogs()
            }
        } catch {
            logFileReadFailed = true
            logPersistenceErrorSource = L10n.snapshotCompose("读取日志失败，原文件已保留；新日志暂时仅在本次运行中显示：%@", .literal(error.localizedDescription))
        }
        updateLogText()
    }
    private func saveTransferLogs() {
        guard !logFileReadFailed else { return }
        do { try logRepository.save(transferLogs); logPersistenceError = "" }
        catch { logPersistenceErrorSource = L10n.snapshotCompose("日志尚未保存到磁盘：%@", .literal(error.localizedDescription)) }
    }
    private func updateLogText() {
        logs = transferLogs.map { "\(L10n.date($0.date, date: .numeric, time: .standard))  \($0.message)" }
    }
    private func sanitizedLogMessage(_ text: String) -> String {
        var value = text
        for secret in Set([password, persistedPassword]).filter({ !$0.isEmpty }).sorted(by: { $0.count > $1.count }) {
            value = value.replacingOccurrences(of: secret, with: L10n.text("[已隐藏]"))
        }
        value = value.components(separatedBy: .controlCharacters).joined(separator: " ")
        return String(value.prefix(2048))
    }
    private func transferSubject(_ entry: HistoryEntry) -> String { transferSubjectSnapshot(entry).rendered }
    private func transferSubjectSnapshot(_ entry: HistoryEntry) -> L10n.Snapshot {
        let name: L10n.Snapshot
        switch entry.kind {
        case .text: name = L10n.snapshot("文本")
        case .image: name = L10n.snapshot("图片")
        case .file:
            let filenames = entry.paths.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: L10n.text("、"))
            name = filenames.isEmpty ? L10n.snapshot("文件") : .verbatim(String(filenames.prefix(240)))
        }
        return L10n.snapshotCompose("%@ [记录 %@]", .snapshot(name), .literal(String(entry.id.uuidString.prefix(8))))
    }
    func persist() {
        do { try repository.save(entries) } catch { logSnapshot(L10n.snapshotFormat("保存历史失败：%@", String(describing: error.localizedDescription)), level: .error) }
    }
    @discardableResult func saveSettings(preferences candidate: AppPreferences? = nil,
                                       password candidatePassword: String? = nil) -> Bool {
        settingsError = ""
        let values = candidate ?? preferences
        let secret = candidatePassword ?? password
        if let issue = values.validationError { settingsErrorSource = L10n.capture(issue); return false }
        let oldSecret = persistedPassword
        var passwordWritten = false
        do {
            let data = try JSONEncoder().encode(values)
            if secret != oldSecret { try writePassword(secret); passwordWritten = true }
            try data.write(to: root.appendingPathComponent("preferences.json"), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: root.appendingPathComponent("preferences.json").path)
            preferences = values; password = secret; persistedPassword = secret
            entries = repository.prune(entries, days: values.ttlDays)
            persist(); logSnapshot(L10n.snapshot("配置已自动保存"))
            return true
        } catch {
            if passwordWritten {
                do { try writePassword(oldSecret) }
                catch { settingsErrorSource = L10n.snapshot("配置保存失败，密码恢复也未完成，请重新检查 FTP 密码"); return false }
            }
            settingsError = error.localizedDescription
            return false
        }
    }
    func migrateOriginalFTP() {
        guard allowsBusinessTransfers else { settingsErrorSource = L10n.snapshot("独立更新测试不迁移原应用配置。"); return }
        settingsError = ""
        let source = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".copy_tool/config.toml")
        let previous = preferences; let oldPassword = password
        let oldPersistedPassword = persistedPassword
        let config = root.appendingPathComponent("preferences.json")
        let oldData = try? Data(contentsOf: config)
        do {
            let imported = try OriginalFTPConfig.load(from: source, preserving: preferences)
            if let oldData {
                let backup = root.appendingPathComponent("preferences.before-ftp-migration-" + UUID().uuidString + ".json")
                try oldData.write(to: backup, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            }
            saveSettings(preferences: imported.preferences, password: imported.password)
            guard settingsError.isEmpty else { throw NSError(domain: "CopyTool", code: 1, userInfo: [NSLocalizedDescriptionKey: settingsError]) }
            guard readPassword() == imported.password else { throw NSError(domain: "CopyTool", code: 2, userInfo: [NSLocalizedDescriptionKey: L10n.text("钥匙串写入后校验未通过")]) }
            logSnapshot(L10n.snapshot("原应用 FTP 配置迁移成功；连接与路由字段已校验"))
        } catch {
            let reason = error.localizedDescription
            preferences = previous; password = oldPassword
            var rollbackError = ""
            if persistedPassword != oldPersistedPassword {
                do { try writePassword(oldPersistedPassword); persistedPassword = oldPersistedPassword }
                catch { rollbackError = L10n.text("；FTP 密码恢复失败，请重新检查密码") }
            }
            if let oldData { try? oldData.write(to: config, options: .atomic) }
            settingsErrorSource = L10n.snapshotCompose("%@%@", .localized(reason), .localized(rollbackError))
            logSnapshot(L10n.snapshot("FTP 配置迁移未完成：").appending(settingsErrorSource), level: .error)
        }
    }
    func sendValidationSamples() {
        guard allowsBusinessTransfers else { return }
        guard !running, tasks.isEmpty else { logSnapshot(L10n.snapshot("请等待当前传输完成后再发送验证样例")); return }
        if let issue = preferences.validationError { logSnapshot(L10n.snapshot("未发送验证样例：").appending(L10n.capture(issue)), level: .error); return }
        guard !password.isEmpty else { logSnapshot(L10n.snapshot("未发送验证样例：FTP 密码缺失"), level: .error); return }
        do {
            let formatter = DateFormatter(); formatter.dateFormat = "yyyyMMdd-HHmmss"; formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
            let runID = "rea-copytool-" + formatter.string(from: Date()) + "-" + UUID().uuidString.prefix(8).lowercased()
            let runRoot = root.appendingPathComponent("Tests/" + runID, isDirectory: true)
            let folder = runRoot.appendingPathComponent(runID + "-folder", isDirectory: true)
            let nested = folder.appendingPathComponent("nested", isDirectory: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let text = "REA copy-tool 接收验证\n测试标识：" + runID + "\n类型：文本，UTF-8 中文与 English，12345。"
            let file = runRoot.appendingPathComponent(runID + "-file.txt")
            try Data(("REA file test\n" + runID + "\n中文文件内容\n").utf8).write(to: file)
            let first = folder.appendingPathComponent("说明.txt")
            let second = nested.appendingPathComponent("check.txt")
            try Data(("REA folder root\n" + runID + "\n").utf8).write(to: first)
            try Data(("REA folder nested\n" + runID + "\n").utf8).write(to: second)
            let samples = [HistoryEntry(kind: .text, content: text), HistoryEntry(kind: .file, content: L10n.text("验证文件"), paths: [file.path]), HistoryEntry(kind: .file, content: L10n.text("验证文件夹"), paths: [folder.path])]
            let hashFiles = [file, first, second].map { url -> [String: String] in
                let data = (try? Data(contentsOf: url)) ?? Data()
                let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                return ["path": url.path, "sha256": hash]
            }
            let manifest: [String: Any] = ["run_id": runID, "text": text, "file_name": file.lastPathComponent, "folder_name": folder.lastPathComponent, "files": hashFiles, "entry_ids": samples.map { $0.id.uuidString }, "endpoint": preferences.host + ":" + String(preferences.port), "destination": preferences.directory]
            try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: runRoot.appendingPathComponent("manifest.json"), options: .atomic)
            entries.insert(contentsOf: samples.reversed(), at: 0); selected = samples.first?.id; persist()
            logSnapshot(L10n.snapshot("开始接收验证：").appending(L10n.Snapshot.verbatim(runID)))
            for sample in samples { enqueue(sample) }
        } catch { logSnapshot(L10n.snapshot("准备验证样例失败：").appending(L10n.capture(error.localizedDescription)), level: .error) }
    }
    // 只由自定义复制完成回调调用；服务确认本次复制改变了剪贴板后才进入这里。
    // 不监听普通剪贴板变化；仅冻结这次明确复制发送的内容。
    func captureClipboardForShortcut(expectedChangeCount: Int) {
        guard allowsBusinessTransfers else { return }
        let pb = NSPasteboard.general
        captureClipboard(pb, expectedChangeCount: expectedChangeCount)
    }
    private func captureClipboard(_ pb: NSPasteboard, expectedChangeCount: Int) {
        guard pb.changeCount == expectedChangeCount else {
            logSnapshot(L10n.snapshot("自定义复制未发送：剪贴板已变化，请重新复制"), level: .warning)
            return
        }
        let snapshot: ClipboardSnapshot?
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            snapshot = .files(urls)
        } else if let data = pb.data(forType: .png) { snapshot = .image(data) }
        else if let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff), let data = rep.representation(using: .png, properties: [:]) { snapshot = .image(data) }
        else if let text = pb.string(forType: .string), !text.isEmpty { snapshot = .text(text) }
        else { snapshot = nil }
        // 先冻结内容，再核对版本；读取期间发生其他复制时不发送混合或过期内容。
        guard pb.changeCount == expectedChangeCount else {
            logSnapshot(L10n.snapshot("自定义复制未发送：读取期间剪贴板已变化，请重新复制"), level: .warning)
            return
        }
        switch snapshot {
        case .files(let urls): addFiles(urls, automatic: false)
        case .image(let data): addImage(data, automatic: false)
        case .text(let text): add(HistoryEntry(kind: .text, content: text), automatic: false)
        case nil: logSnapshot(L10n.snapshot("自定义复制未发送：剪贴板中没有支持的文本、图片或文件"), level: .warning)
        }
    }
    func addImage(_ data: Data, automatic: Bool = true) {
        guard allowsBusinessTransfers else { return }
        guard !automatic else { return }
        do { let file = try repository.saveImage(data); add(HistoryEntry(kind: .image, content: L10n.text("剪贴板图片"), paths: [file.path]), automatic: automatic) }
        catch { logSnapshot(L10n.snapshotFormat("图片保存失败：%@", String(describing: error.localizedDescription)), level: .error) }
    }
    func addFiles(_ urls: [URL], automatic: Bool = true) {
        guard allowsBusinessTransfers else { return }
        guard !automatic else { return }
        let paths = urls.filter(\.isFileURL).map(\.path)
        guard !paths.isEmpty else { return }
        add(HistoryEntry(kind: .file, content: L10n.format("%@ 个文件", String(describing: paths.count)), paths: paths), automatic: automatic)
    }
    func add(_ item: HistoryEntry, automatic: Bool) {
        guard allowsBusinessTransfers else { return }
        // 防御旧调用：普通复制既不留历史/缓存，也不进入发送流程。
        guard !automatic else { return }
        if let first = entries.first, first.kind == item.kind && first.content == item.content && first.paths == item.paths {
            selected = first.id; enqueue(first)
            return
        }
        if preferences.historyEnabled { entries.insert(item, at: 0); selected = item.id; persist() }
        logSnapshot(L10n.snapshotFormat("准备发送：%@", String(describing: item.kind == .text ? L10n.text("文本") : item.content)))
        enqueue(item)
    }
    func chooseFiles() {
        guard allowsBusinessTransfers else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.begin { [weak self] response in if response == .OK { Task { @MainActor in self?.addFiles(panel.urls, automatic: false) } } }
    }
    func restore(_ entry: HistoryEntry) {
        guard allowsBusinessTransfers else { return }
        let pb = NSPasteboard.general; pb.clearContents()
        if entry.kind == .text { pb.setString(entry.content, forType: .string) }
        else if entry.kind == .image, let path = entry.paths.first, let data = try? Data(contentsOf: URL(fileURLWithPath: path)) { pb.setData(data, forType: .png) }
        else { pb.writeObjects(entry.paths.map { NSURL(fileURLWithPath: $0) }) }
        logSnapshot(L10n.snapshot("已恢复到系统剪贴板"))
    }
    func resend(_ entry: HistoryEntry) {
        if preferences.restoreOnResend { restore(entry) }
        enqueue(entry)
    }
    func enqueue(_ entry: HistoryEntry) {
        guard allowsBusinessTransfers else { logSnapshot(L10n.snapshot("独立更新测试不执行普通 FTP 传输")); return }
        guard !updateInstallationIsCommitting else { logSnapshot(L10n.snapshot("正在安装更新，请稍后再发送"), level: .warning); return }
        if let issue = preferences.validationError { logSnapshot(L10n.snapshotFormat("未发送：%@", String(describing: issue)), level: .error); return }
        guard !password.isEmpty else { logSnapshot(L10n.snapshot("未发送：请在设置中填写密码"), level: .error); return }
        tasks.append((entry, preferences, password)); queued = tasks.count
        transferSnapshot.queuedCount = queued
        logSnapshot(L10n.snapshotCompose("已加入发送队列：%@ · 等待 %@ 项", .snapshot(transferSubjectSnapshot(entry)), .literal(String(queued))))
        updateStatus(entry.id, "等待发送"); beginNext()
    }
    func updateStatus(_ id: UUID, _ status: String) {
        if let i = entries.firstIndex(where: { $0.id == id }) { entries[i].status = status; persist() }
    }
    func beginNext() {
        guard allowsBusinessTransfers else { return }
        guard !running, !tasks.isEmpty else { return }
        let (entry, config, secret) = tasks.removeFirst(); queued = tasks.count
        running = true; cancelling = false
        transferTitleSource = entry.kind == .text ? L10n.snapshot("文本") : .verbatim(entry.title)
        activeTransfer = transferTitleSource.rendered; progress = 0
        let token = UUID()
        activeTransferToken = token; progressFileIndex = -1
        let subjectSource = transferSubjectSnapshot(entry)
        let attempt = String(token.uuidString.prefix(8))
        logSnapshot(L10n.snapshotCompose("开始发送：%@ · 任务 %@", .snapshot(subjectSource), .literal(attempt)))
        transferSnapshot = TransferProgressSnapshot(id: token, phase: .preparing, title: activeTransfer,
            queuedCount: queued, detail: L10n.text("正在准备文件…"))
        transferDetailSource = L10n.snapshot("正在准备文件…")
        updateStatus(entry.id, "发送中")
        let ftp = FTPSettings(host: config.host, port: config.port, username: config.username, password: secret, directory: config.directory)
        let transfer = self.transfer
        transfer.resetCancellation()
        worker.async { [self] in
            UpdateTransferGate.shared.beginBusiness()
            defer { UpdateTransferGate.shared.end() }
            var temporary: [URL] = []
            defer { for url in temporary { try? FileManager.default.removeItem(at: url) } }
            do {
                let plan = try TransferProtocol.prepare(entry: entry, preferences: config,
                    timestamp: Int64(Date().timeIntervalSince1970 * 1000), transfer: transfer)
                temporary = plan.temporaryFiles
                try transfer.checkCancellation()
                let sizes = try plan.files.map { upload in
                    Int64(try upload.file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
                }
                let byteProgress = TransferByteProgress(fileSizes: sizes)
                DispatchQueue.main.sync {
                    MainActor.assumeIsolated {
                        guard self.activeTransferToken == token, !self.cancelling else { return }
                        let bytes = sizes.reduce(Int64(0)) { result, size in
                            let sum = result.addingReportingOverflow(size)
                            return sum.overflow ? Int64.max : sum.partialValue
                        }
                        for folder in plan.groupedFileFolders {
                            self.logSnapshot(L10n.snapshotFormat("同名不同后缀文件已合并为文件夹：%@；接收后在该文件夹内查看原文件 · 任务 %@", String(describing: folder), String(describing: attempt)))
                        }
                        let exclusions = plan.excludedItemCount > 0 ? L10n.format(" · 已排除 %@ 项（目录按 1 项计）", String(describing: plan.excludedItemCount)) : ""
                        self.logSnapshot(L10n.snapshotCompose("准备完成：%@ · %@%@ · 任务 %@", .snapshot(subjectSource), .literal(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)), .localized(exclusions), .literal(attempt)))
                    }
                }
                for (index, upload) in plan.files.enumerated() {
                    try transfer.checkCancellation()
                    var destination = ftp; destination.directory = upload.directory
                    let publishing = entry.kind != .text && index == plan.files.count - 1
                    let itemName = entry.paths.indices.contains(index) ? URL(fileURLWithPath: entry.paths[index]).lastPathComponent : ""
                    DispatchQueue.main.sync {
                        MainActor.assumeIsolated {
                            guard self.activeTransferToken == token, !self.cancelling else { return }
                            let stage = publishing ? L10n.text("正在完成投递") : L10n.text("开始上传")
                            self.logSnapshot(L10n.snapshotCompose("%@：%@ · 第 %@/%@ 项 · 任务 %@", .localized(stage), .snapshot(subjectSource), .literal(String(index + 1)), .literal(String(plan.files.count)), .literal(attempt)))
                        }
                    }
                    try transfer.upload(file: upload.file, remoteName: upload.remoteName, settings: destination) { value in
                        let values = byteProgress.update(fileIndex: index, fraction: value)
                        Task { @MainActor in
                            self.reportTransferProgress(token: token, fileIndex: index, values: values,
                                itemName: itemName, publishing: publishing)
                        }
                    }
                }
                Task { @MainActor in self.finish(entry, error: nil, token: token) }
            } catch FTPTransferError.cancelled {
                Task { @MainActor in self.finish(entry, error: nil, token: token, wasCancelled: true) }
            } catch { Task { @MainActor in self.finish(entry, error: error.localizedDescription, token: token) } }
        }
    }
    func reportTransferProgress(token: UUID, fileIndex: Int, values: TransferProgressValues,
                                itemName: String, publishing: Bool) {
        guard running, activeTransferToken == token, !cancelling, fileIndex >= progressFileIndex else { return }
        progressFileIndex = fileIndex
        // 服务器确认最后控制文件前保留 99%，不能用数据写完冒充整笔投递完成。
        progress = max(progress, min(0.99, values.fraction))
        transferSnapshot.phase = publishing ? .publishing : .uploading
        transferSnapshot.fraction = progress
        transferSnapshot.uploadedBytes = max(transferSnapshot.uploadedBytes, values.uploadedBytes)
        transferSnapshot.totalBytes = values.totalBytes
        transferSnapshot.currentItem = itemName
        transferSnapshot.queuedCount = queued
        transferDetailSource = publishing ? L10n.snapshot("正在完成投递…") : L10n.snapshot("正在上传…")
        transferSnapshot.detail = transferDetailSource.rendered
    }
    func finish(_ entry: HistoryEntry, error: String?, token: UUID, wasCancelled: Bool = false) {
        guard running, activeTransferToken == token else { return }
        let cancelled = cancelling || wasCancelled
        let succeeded = !cancelled && error == nil
        running = false; activeTransfer = ""; progress = 0
        activeTransferToken = nil
        transferSnapshot.phase = cancelled ? .cancelled : (succeeded ? .completed : .failed)
        transferSnapshot.queuedCount = queued
        transferDetailSource = cancelled ? L10n.snapshot("传输已取消") : (succeeded ? L10n.snapshot("FTP 上传完成") : L10n.snapshot("请在传输日志查看原因"))
        transferSnapshot.detail = transferDetailSource.rendered
        if succeeded {
            transferSnapshot.fraction = 1
            transferSnapshot.uploadedBytes = transferSnapshot.totalBytes
        }
        let state = cancelled ? "已取消" : (succeeded ? "已发送" : "发送失败")
        updateStatus(entry.id, state)
        let result = cancelled ? L10n.text("传输已取消") : (succeeded ? L10n.text("FTP 上传完成") : L10n.format("发送失败：%@", String(describing: error ?? L10n.text("未知错误"))))
        logSnapshot(L10n.snapshotCompose("%@ · %@ · 任务 %@", .localized(result), .snapshot(transferSubjectSnapshot(entry)), .literal(String(token.uuidString.prefix(8)))),
            level: cancelled ? .cancelled : (succeeded ? .success : .error))
        beginNext()
    }
    func cancelAll() {
        for task in tasks {
            updateStatus(task.0.id, "已取消")
            logSnapshot(L10n.snapshotCompose("等待任务已取消：%@", .snapshot(transferSubjectSnapshot(task.0))), level: .cancelled)
        }
        tasks.removeAll(); queued = 0
        transferSnapshot.queuedCount = 0
        if running {
            cancelling = true
            transferSnapshot.phase = .cancelling
            transferDetailSource = L10n.snapshot("正在取消…")
            transferSnapshot.detail = transferDetailSource.rendered
        }
        transfer.cancel(); logSnapshot(L10n.snapshot("已请求取消传输"), level: .warning)
    }
    func delete(_ entry: HistoryEntry) {
        entries.removeAll { $0.id == entry.id }; persist()
        do { try repository.removeUnreferencedMedia(entries: entries) } catch { logSnapshot(L10n.snapshot("清理图片失败")) }
    }
    func clearHistory() {
        entries.removeAll(); selected = nil; persist()
        do { try repository.removeUnreferencedMedia(entries: []) } catch { logSnapshot(L10n.snapshot("清理图片失败")) }
        logSnapshot(L10n.snapshot("已清空本应用历史；源文件保留"))
    }
}
