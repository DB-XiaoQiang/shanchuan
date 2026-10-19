import Foundation

public struct FTPSettings: Codable, Equatable, Sendable {
    public var host: String
    public var port: Int
    public var username: String
    public var password: String
    public var directory: String

    public init(host: String = "", port: Int = 21, username: String = "", password: String = "", directory: String = "/") {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.directory = directory
    }
}

public enum FTPTransferError: Error, LocalizedError {
    case invalidSettings(String)
    case invalidFile
    case cancelled
    case failed(Int32, String)

    public var errorDescription: String? {
        switch self {
        case .invalidSettings(let reason): return reason
        case .invalidFile: return "上传源必须是可读取的普通文件。"
        case .cancelled: return "上传已取消。"
        case .failed(let status, let detail): return "传输失败（\(status)）：\(detail)"
        }
    }
}

/// Synchronous worker. Call on a background queue; create one instance per serial queue.
/// Credentials enter curl through stdin, never command-line arguments or temporary config files.
public final class FTPTransfer: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    public init() {}

    public func resetCancellation() {
        lock.lock(); defer { lock.unlock() }
        cancelled = false
    }

    public func checkCancellation() throws {
        lock.lock(); let wasCancelled = cancelled; lock.unlock()
        if wasCancelled { throw FTPTransferError.cancelled }
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        let current = process
        lock.unlock()
        if let current, current.isRunning { current.terminate() }
    }

    public func upload(file: URL, remoteName: String, settings: FTPSettings, progress: @escaping @Sendable (Double) -> Void) throws {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey])
        guard values.isRegularFile == true, values.isReadable == true else { throw FTPTransferError.invalidFile }
        let host = settings.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !host.contains(where: { "/@?#\\\r\n\t ".contains($0) }), (1...65535).contains(settings.port) else {
            throw FTPTransferError.invalidSettings("请填写有效的 FTP 主机和端口。")
        }
        guard !settings.username.contains(":"), !settings.username.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }), !settings.password.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw FTPTransferError.invalidSettings("FTP 用户名不能包含冒号，凭据不能包含控制字符。")
        }
        guard !remoteName.isEmpty, remoteName != ".", remoteName != "..", !remoteName.contains("/"), !remoteName.contains("\\"), !remoteName.contains("\0") else {
            throw FTPTransferError.invalidSettings("远端文件名必须是单个有效文件名。")
        }
        let segments = settings.directory.split(separator: "/").map(String.init)
        guard !segments.contains(".."), !settings.directory.contains("\0") else {
            throw FTPTransferError.invalidSettings("远端目录不能包含上级目录路径。")
        }
        var components = URLComponents()
        components.scheme = "ftp"
        components.host = host
        components.port = settings.port
        // Double slash gives FTP an absolute path instead of a login-relative path.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        components.percentEncodedPath = "//" + (segments + [remoteName]).map { $0.addingPercentEncoding(withAllowedCharacters: allowed)! }.joined(separator: "/")
        guard let target = components.url?.absoluteString else { throw FTPTransferError.invalidSettings("FTP 地址无效。") }
        let config = "user = \(Self.quote(settings.username + ":" + settings.password))\nurl = \(Self.quote(target))\n"
        progress(0)
        try run(executable: "/usr/bin/curl", arguments: ["--disable", "--config", "-", "--noproxy", "*", "--proto", "=ftp", "--ftp-create-dirs", "--connect-timeout", "15", "--speed-time", "60", "--speed-limit", "1", "--fail", "--show-error", "--progress-bar", "--upload-file", file.path], stdin: Data(config.utf8), progress: progress, secrets: [settings.password, settings.username + ":" + settings.password])
        progress(1)
    }

    public func upload(text: String, remoteName: String, settings: FTPSettings, progress: @escaping @Sendable (Double) -> Void) throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("copytool-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(text.utf8).write(to: file, options: [.atomic])
        try upload(file: file, remoteName: remoteName, settings: settings, progress: progress)
    }

    public static func archiveDirectory(_ source: URL, destination: URL) throws {
        try FTPTransfer().zip(directory: source, destination: destination)
    }

    /// Caller owns and removes destination after uploading it.
    public func zip(directory: URL, destination: URL) throws {
        guard (try directory.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else { throw FTPTransferError.invalidFile }
        try run(executable: "/usr/bin/ditto", arguments: ["-c", "-k", "--norsrc", directory.path, destination.path], stdin: Data(), progress: { _ in }, secrets: [])
        do { try normalizeZIPEncoding(at: destination) }
        catch { try? FileManager.default.removeItem(at: destination); throw error }
    }

    /// ditto emits UTF-8 path bytes without the language-encoding bit on some macOS versions.
    /// Walk directory records and their explicit local-header offsets; never scan compressed payloads.
    func normalizeZIPEncoding(at url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        func invalid() -> FTPTransferError { .failed(-1, "ZIP 目录结构或 UTF-8 文件名无效。") }
        func read(_ offset: UInt64, _ count: Int) throws -> Data {
            guard offset <= size, UInt64(count) <= size - offset else { throw invalid() }
            if count == 0 { return Data() }
            try handle.seek(toOffset: offset)
            guard let data = try handle.read(upToCount: count), data.count == count else { throw invalid() }
            return data
        }
        func number(_ data: Data, _ offset: Int, _ count: Int) -> UInt64 {
            (0..<count).reduce(0) { $0 | UInt64(data[offset + $1]) << ($1 * 8) }
        }
        func flag(_ offset: UInt64, _ original: UInt64) throws {
            let value = original | 0x800
            try handle.seek(toOffset: offset)
            try handle.write(contentsOf: Data([UInt8(value & 255), UInt8((value >> 8) & 255)]))
        }
        guard size >= 22 else { throw invalid() }
        let tailCount = Int(min(size, 65_557))
        let tailOffset = size - UInt64(tailCount)
        let tail = try read(tailOffset, tailCount)
        var endIndex: Int?
        for index in stride(from: tailCount - 22, through: 0, by: -1) {
            if number(tail, index, 4) == 0x06054b50,
               index + 22 + Int(number(tail, index + 20, 2)) == tailCount {
                endIndex = index
                break
            }
        }
        guard let endIndex else { throw invalid() }
        let endOffset = tailOffset + UInt64(endIndex)
        guard number(tail, endIndex + 4, 2) == 0, number(tail, endIndex + 6, 2) == 0,
              number(tail, endIndex + 8, 2) == number(tail, endIndex + 10, 2) else { throw invalid() }
        var count = number(tail, endIndex + 10, 2)
        var directorySize = number(tail, endIndex + 12, 4)
        var directoryOffset = number(tail, endIndex + 16, 4)
        var directoryLimit = endOffset
        if count == 0xffff || directorySize == 0xffffffff || directoryOffset == 0xffffffff {
            guard endOffset >= 20 else { throw invalid() }
            let locator = try read(endOffset - 20, 20)
            guard number(locator, 0, 4) == 0x07064b50, number(locator, 4, 4) == 0,
                  number(locator, 16, 4) == 1 else { throw invalid() }
            let zip64Offset = number(locator, 8, 8)
            let record = try read(zip64Offset, 56)
            let recordSize = number(record, 4, 8)
            guard number(record, 0, 4) == 0x06064b50, recordSize >= 44,
                  zip64Offset <= endOffset - 20, recordSize <= endOffset - 20 - zip64Offset,
                  endOffset - 20 - zip64Offset - recordSize == 12,
                  number(record, 16, 4) == 0, number(record, 20, 4) == 0,
                  number(record, 24, 8) == number(record, 32, 8) else { throw invalid() }
            count = number(record, 32, 8)
            directorySize = number(record, 40, 8)
            directoryOffset = number(record, 48, 8)
            directoryLimit = zip64Offset
        }
        guard directoryOffset <= directoryLimit, directorySize <= directoryLimit - directoryOffset,
              count <= directorySize / 46 else { throw invalid() }
        let directoryEnd = directoryOffset + directorySize
        var cursor = directoryOffset
        for _ in 0..<count {
            lock.lock(); let wasCancelled = cancelled; lock.unlock()
            if wasCancelled { throw FTPTransferError.cancelled }
            guard cursor <= directoryEnd, directoryEnd - cursor >= 46 else { throw invalid() }
            let central = try read(cursor, 46)
            guard number(central, 0, 4) == 0x02014b50 else { throw invalid() }
            let nameLength = Int(number(central, 28, 2))
            let extraLength = Int(number(central, 30, 2))
            let commentLength = Int(number(central, 32, 2))
            let recordLength = UInt64(46 + nameLength + extraLength + commentLength)
            guard recordLength <= directoryEnd - cursor else { throw invalid() }
            let name = try read(cursor + 46, nameLength)
            let extra = try read(cursor + 46 + UInt64(nameLength), extraLength)
            let comment = try read(cursor + 46 + UInt64(nameLength + extraLength), commentLength)
            guard String(data: name, encoding: .utf8) != nil,
                  String(data: comment, encoding: .utf8) != nil else { throw invalid() }
            var localOffset = number(central, 42, 4)
            let disk = number(central, 34, 2)
            if localOffset == 0xffffffff || disk == 0xffff {
                var extraCursor = 0
                var found = false
                while extraCursor + 4 <= extra.count {
                    let identifier = number(extra, extraCursor, 2)
                    let length = Int(number(extra, extraCursor + 2, 2))
                    guard length <= extra.count - extraCursor - 4 else { throw invalid() }
                    if identifier == 1 {
                        var field = extraCursor + 4
                        let limit = field + length
                        if number(central, 24, 4) == 0xffffffff { field += 8 }
                        if number(central, 20, 4) == 0xffffffff { field += 8 }
                        if localOffset == 0xffffffff {
                            guard field + 8 <= limit else { throw invalid() }
                            localOffset = number(extra, field, 8); field += 8
                        }
                        if disk == 0xffff {
                            guard field + 4 <= limit, number(extra, field, 4) == 0 else { throw invalid() }
                        } else if disk != 0 { throw invalid() }
                        found = true
                        break
                    }
                    extraCursor += 4 + length
                }
                guard found else { throw invalid() }
            } else if disk != 0 { throw invalid() }
            guard localOffset < directoryOffset, directoryOffset - localOffset >= 30 else { throw invalid() }
            let local = try read(localOffset, 30)
            let localNameLength = Int(number(local, 26, 2))
            let localExtraLength = Int(number(local, 28, 2))
            guard number(local, 0, 4) == 0x04034b50,
                  UInt64(30 + localNameLength + localExtraLength) <= directoryOffset - localOffset,
                  localNameLength == nameLength,
                  try read(localOffset + 30, localNameLength) == name else { throw invalid() }
            try flag(cursor + 8, number(central, 8, 2))
            try flag(localOffset + 6, number(local, 6, 2))
            cursor += recordLength
        }
        guard cursor == directoryEnd else { throw invalid() }
        try handle.synchronize()
    }

    private static func quote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\t", with: "\\t").replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\u{000B}", with: "\\v") + "\""
    }

    private func run(executable: String, arguments: [String], stdin: Data, progress: @escaping @Sendable (Double) -> Void, secrets: [String]) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        let input = Pipe(), output = Pipe()
        task.standardInput = input
        task.standardError = output
        task.standardOutput = FileHandle.nullDevice
        lock.lock()
        guard !cancelled else { lock.unlock(); throw FTPTransferError.cancelled }
        process = task
        do { try task.run() } catch { process = nil; lock.unlock(); throw error }
        lock.unlock()
        defer { lock.lock(); process = nil; lock.unlock() }
        // Config is bounded and small; curl consumes it before starting the transfer.
        do { try input.fileHandleForWriting.write(contentsOf: stdin); try input.fileHandleForWriting.close() }
        catch { task.terminate(); task.waitUntilExit(); throw error }
        var diagnostic = Data()
        let expression = try NSRegularExpression(pattern: #"([0-9]+(?:\.[0-9]+)?)%"#)
        var lastProgress = 0.0
        while true {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            diagnostic.append(chunk)
            if diagnostic.count > 16_384 { diagnostic = diagnostic.suffix(16_384) }
            let text = String(decoding: diagnostic, as: UTF8.self)
            if let match = expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
               let range = Range(match.range(at: 1), in: text), let percentage = Double(text[range]) {
                let value = min(0.99, max(lastProgress, percentage / 100))
                if value > lastProgress { lastProgress = value; progress(value) }
            }
        }
        task.waitUntilExit()
        lock.lock(); let wasCancelled = cancelled; lock.unlock()
        if wasCancelled { throw FTPTransferError.cancelled }
        if task.terminationStatus != 0 {
            var detail = String(decoding: diagnostic, as: UTF8.self)
            for secret in secrets where !secret.isEmpty { detail = detail.replacingOccurrences(of: secret, with: "[redacted]") }
            throw FTPTransferError.failed(task.terminationStatus, detail.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
