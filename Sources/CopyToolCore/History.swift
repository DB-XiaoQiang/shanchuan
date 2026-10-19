import Foundation

public struct HistoryEntry: Identifiable, Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case text, file, image }
    public var id: UUID
    public var date: Date
    public var kind: Kind
    public var content: String
    public var paths: [String]
    public var status: String
    public init(kind: Kind, content: String, paths: [String] = [], date: Date = Date()) {
        self.id = UUID(); self.date = date; self.kind = kind; self.content = content; self.paths = paths; self.status = "仅本地"
    }
    public var title: String { kind == .text ? content : paths.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: "、") }
    public func matches(query: String, kind: Kind?) -> Bool {
        (kind == nil || self.kind == kind) && (query.isEmpty || title.localizedCaseInsensitiveContains(query))
    }
}

public struct AppPreferences: Codable, Equatable, Sendable {
    public var host = ""
    public var port = 21
    public var username = ""
    public var directory = "/"
    public var ttlDays = 90
    // 仅兼容旧配置；普通剪贴板变化永不据此上传。
    public var syncEnabled = false
    public var historyEnabled = true
    public var notificationsEnabled = false
    public var showTransferProgress = true
    public var restoreOnResend = false
    public var textRemoteName = "copy.temp"
    public var autoDecrypt = true
    public var decryptPrefix = "/jiemi/"
    public var shortcuts = CopyPasteShortcuts()
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case host, port, username, directory, ttlDays, syncEnabled, historyEnabled
        case notificationsEnabled, showTransferProgress, restoreOnResend, textRemoteName
        case autoDecrypt, decryptPrefix, shortcuts
    }
    public init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        host = try values.decodeIfPresent(String.self, forKey: .host) ?? host
        port = try values.decodeIfPresent(Int.self, forKey: .port) ?? port
        username = try values.decodeIfPresent(String.self, forKey: .username) ?? username
        directory = try values.decodeIfPresent(String.self, forKey: .directory) ?? directory
        ttlDays = try values.decodeIfPresent(Int.self, forKey: .ttlDays) ?? ttlDays
        syncEnabled = try values.decodeIfPresent(Bool.self, forKey: .syncEnabled) ?? syncEnabled
        historyEnabled = try values.decodeIfPresent(Bool.self, forKey: .historyEnabled) ?? historyEnabled
        notificationsEnabled = try values.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? notificationsEnabled
        showTransferProgress = try values.decodeIfPresent(Bool.self, forKey: .showTransferProgress) ?? showTransferProgress
        restoreOnResend = try values.decodeIfPresent(Bool.self, forKey: .restoreOnResend) ?? restoreOnResend
        textRemoteName = try values.decodeIfPresent(String.self, forKey: .textRemoteName) ?? textRemoteName
        autoDecrypt = try values.decodeIfPresent(Bool.self, forKey: .autoDecrypt) ?? autoDecrypt
        decryptPrefix = try values.decodeIfPresent(String.self, forKey: .decryptPrefix) ?? decryptPrefix
        shortcuts = try values.decodeIfPresent(CopyPasteShortcuts.self, forKey: .shortcuts) ?? shortcuts
    }
    public var validationError: String? {
        if host.isEmpty { return "请填写 FTP 服务器地址" }
        if host.contains(where: { $0.isWhitespace }) || host.contains("://") || host.contains("/") { return "服务器地址只能填写主机名或 IP" }
        if !(1...65535).contains(port) { return "端口须为 1–65535" }
        if username.isEmpty { return "请填写用户名" }
        if !directory.hasPrefix("/") || directory.contains("\n") || directory.contains("\r") { return "FTP 目录须以 / 开头" }
        if ttlDays < 1 || ttlDays > 3650 { return "历史保留天数须为 1–3650" }
        if textRemoteName.isEmpty || textRemoteName.contains("/") || textRemoteName.contains("\n") || textRemoteName.contains("\r") { return "文本远端文件名无效" }
        return shortcuts.validationError
    }
}

public struct HistoryRepository {
    public let root: URL
    public var mediaDirectory: URL { root.appendingPathComponent("Media", isDirectory: true) }
    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    public func load() throws -> [HistoryEntry] {
        let file = root.appendingPathComponent("history.json")
        if !FileManager.default.fileExists(atPath: file.path) { return [] }
        return try JSONDecoder().decode([HistoryEntry].self, from: Data(contentsOf: file))
    }
    public func save(_ entries: [HistoryEntry]) throws {
        let file = root.appendingPathComponent("history.json")
        try JSONEncoder().encode(entries).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    public func prune(_ entries: [HistoryEntry], days: Int, now: Date = Date()) -> [HistoryEntry] {
        let cutoff = now.addingTimeInterval(-Double(max(1, days)) * 86400)
        return entries.filter { $0.date >= cutoff }
    }
    public func saveImage(_ data: Data) throws -> URL {
        let url = mediaDirectory.appendingPathComponent(UUID().uuidString + ".png")
        try data.write(to: url, options: .atomic)
        return url
    }
    public func removeUnreferencedMedia(entries: [HistoryEntry]) throws {
        let referenced = Set(entries.flatMap(\.paths))
        for url in try FileManager.default.contentsOfDirectory(at: mediaDirectory, includingPropertiesForKeys: nil) where !referenced.contains(url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
