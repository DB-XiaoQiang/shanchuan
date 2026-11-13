import SwiftUI
import CopyToolCore

/// 保留输入草稿，只把校验通过的完整配置交给持久化；关窗时同步提交最后一次修改。
@MainActor final class SettingsAutosaveStore: ObservableObject {
    enum Status: Equatable {
        case ready, pending, saved, failed(String)
        var text: String {
            switch self {
            case .ready: return L10n.text("修改后自动保存")
            case .pending: return L10n.text("保存中…")
            case .saved: return L10n.text("已自动保存")
            case .failed(let error): return L10n.compose("未保存：%@", .localized(error))
            }
        }
    }

    @Published var draft = AppPreferences()
    @Published var secret = ""
    @Published var portText = "21"
    @Published private(set) var status = Status.ready {
        didSet {
            if case .failed(let text) = status { failureSource = L10n.capture(text) }
            else { failureSource = nil }
        }
    }
    private var failureSource: L10n.Snapshot?
    var localizedStatusText: String {
        if case .failed(let text) = status {
            return L10n.snapshotCompose("未保存：%@", .snapshot(failureSource ?? L10n.capture(text))).rendered
        }
        return status.text
    }
    private var baseline = AppPreferences()
    private var baselineSecret = ""
    private var baselinePort = "21"
    private var current: (() -> (AppPreferences, String))?
    private var save: ((AppPreferences, String) -> String?)?
    private var saveFailureOrigin: (() -> L10n.Snapshot?)?
    private var pendingTask: Task<Void, Never>?
    private let delayNanoseconds: UInt64

    init(delayNanoseconds: UInt64 = 500_000_000) { self.delayNanoseconds = delayNanoseconds }

    func connect(current: @escaping () -> (AppPreferences, String),
                 save: @escaping (AppPreferences, String) -> String?,
                 failureOrigin: (() -> L10n.Snapshot?)? = nil) {
        self.current = current
        self.save = save
        self.saveFailureOrigin = failureOrigin
        reload()
    }

    func reload() {
        pendingTask?.cancel(); pendingTask = nil
        guard let (preferences, password) = current?() else { return }
        baseline = preferences; baselineSecret = password; baselinePort = String(preferences.port)
        draft = preferences; secret = password; portText = baselinePort
        status = .ready
    }

    func schedule() {
        pendingTask?.cancel(); pendingTask = nil
        guard current != nil else { return }
        guard isDirty else {
            if status != .ready { status = .saved }
            return
        }
        if let error = validationError { status = .failed(error); return }
        status = .pending
        pendingTask = Task { @MainActor [weak self, delayNanoseconds] in
            do { try await Task.sleep(nanoseconds: delayNanoseconds) } catch { return }
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    func flush() {
        pendingTask?.cancel(); pendingTask = nil
        guard let current, let save else { return }
        guard isDirty else {
            if status != .ready { status = .saved }
            return
        }
        if let error = validationError { status = .failed(error); return }
        let latest = current()
        var values = draft
        values.port = Int(portText)!
        // 快捷键独立自动保存；提交时合并最新值，避免旧草稿覆盖新组合。
        values.shortcuts = latest.0.shortcuts
        values.syncEnabled = latest.0.syncEnabled
        if values != latest.0 || secret != latest.1 {
            if let error = save(values, secret) {
                let origin = saveFailureOrigin?() ?? .verbatim(error)
                status = .failed(origin.rendered); failureSource = origin
                return
            }
        }
        baseline = draft; baselineSecret = secret; baselinePort = portText
        status = .saved
    }

    private var isDirty: Bool {
        draft != baseline || secret != baselineSecret || portText != baselinePort
    }

    private var validationError: String? {
        guard let port = Int(portText), (1...65535).contains(port) else { return L10n.text("端口须为 1–65535") }
        var values = draft; values.port = port
        if let latest = current?() { values.shortcuts = latest.0.shortcuts }
        return values.validationError
    }

    deinit { pendingTask?.cancel() }
}
