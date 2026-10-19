import Foundation
import Darwin

public struct TransferLogEntry: Identifiable, Codable, Equatable, Sendable {
    public enum Level: String, Codable, CaseIterable, Sendable {
        case info, success, warning, error, cancelled
    }

    public var id: UUID
    public var date: Date
    public var level: Level
    public var message: String

    public init(id: UUID = UUID(), date: Date = Date(), level: Level = .info, message: String) {
        self.id = id
        self.date = date
        self.level = level
        self.message = message
    }
}

/// 调用方按最新在前传入日志；仓库保留原顺序，不按时间重新排序。
public struct TransferLogRepository {
    public let root: URL
    public let limit: Int
    public var file: URL { root.appendingPathComponent("transfer-logs.json") }

    public init(root: URL, limit: Int = 1000) {
        self.root = root
        self.limit = max(0, limit)
    }

    public func load() throws -> [TransferLogEntry] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let entries = try JSONDecoder().decode([TransferLogEntry].self, from: Data(contentsOf: file))
        return Array(entries.prefix(limit))
    }

    public func save(_ entries: [TransferLogEntry]) throws {
        let data = try JSONEncoder().encode(Array(entries.prefix(limit)))
        let temporary = root.appendingPathComponent(".transfer-logs-\(UUID().uuidString).tmp")
        // 临时文件从创建起仅当前用户可读写；同目录 rename 原子替换旧日志。
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw currentPOSIXError() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: temporary)
        }
        try handle.write(contentsOf: data)
        try handle.close()
        guard Darwin.rename(temporary.path, file.path) == 0 else { throw currentPOSIXError() }
    }

    private func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
