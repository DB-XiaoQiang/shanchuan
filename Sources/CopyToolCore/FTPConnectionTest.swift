import Foundation
import Darwin

public enum FTPConnectionTestError: Error, LocalizedError, Equatable {
    case invalidSettings(String)
    case authenticationFailed
    case unavailable
    case timedOut
    case directoryUnavailable
    case cancelled
    case alreadyRunning
    case failed(Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidSettings(let reason): return reason
        case .authenticationFailed: return "FTP 登录失败，请检查用户名和密码。"
        case .unavailable: return "无法连接 FTP 服务，请检查主机、端口和网络。"
        case .timedOut: return "FTP 连接超时，请检查服务状态和网络。"
        case .directoryUnavailable: return "FTP 已连接，但无法进入目标目录，请检查目录路径和访问权限。"
        case .cancelled: return "FTP 连接测试已取消。"
        case .alreadyRunning: return "FTP 连接测试正在进行。"
        case .failed(let code): return "FTP 连接测试失败（\(code)），请检查服务状态和配置。"
        }
    }
}

/// A read-only, synchronous FTP login and destination-directory check. Run off the main thread.
/// Create a separate instance for each test. Cancellation never affects an upload worker.
/// A successful result does not establish write permission or receipt by the intranet app.
public final class FTPConnectionTest: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.lock()
        cancelled = true
        let current = process
        lock.unlock()
        if let current, current.isRunning { current.terminate() }
    }

    public func test(settings: FTPSettings) throws {
        lock.lock()
        let wasCancelled = cancelled
        lock.unlock()
        if wasCancelled { throw FTPConnectionTestError.cancelled }
        let config = try Self.configuration(settings: settings)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        task.arguments = [
            "--disable", "--config", "-", "--noproxy", "*", "--proto", "=ftp",
            "--connect-timeout", "8", "--max-time", "15", "--head", "--silent", "--globoff"
        ]
        let input = Pipe()
        task.standardInput = input
        // Discard server diagnostics completely: servers may echo credentials or arbitrary text.
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        lock.lock()
        guard !cancelled else { lock.unlock(); throw FTPConnectionTestError.cancelled }
        guard process == nil else { lock.unlock(); throw FTPConnectionTestError.alreadyRunning }
        process = task
        do { try task.run() }
        catch { process = nil; lock.unlock(); throw FTPConnectionTestError.unavailable }
        lock.unlock()
        defer {
            try? input.fileHandleForWriting.close()
            lock.lock(); process = nil; lock.unlock()
        }
        do {
            try input.fileHandleForWriting.write(contentsOf: Data(config.utf8))
            try input.fileHandleForWriting.close()
        } catch {
            if task.isRunning { task.terminate() }
            task.waitUntilExit()
            lock.lock(); let stopped = cancelled; lock.unlock()
            if stopped { throw FTPConnectionTestError.cancelled }
            throw FTPConnectionTestError.unavailable
        }
        task.waitUntilExit()
        lock.lock(); let stopped = cancelled; lock.unlock()
        if stopped { throw FTPConnectionTestError.cancelled }
        switch task.terminationStatus {
        case 0: return
        case 67: throw FTPConnectionTestError.authenticationFailed
        case 5, 6, 7: throw FTPConnectionTestError.unavailable
        case 28: throw FTPConnectionTestError.timedOut
        case 9, 21: throw FTPConnectionTestError.directoryUnavailable
        default: throw FTPConnectionTestError.failed(task.terminationStatus)
        }
    }

    /// Internal for boundary tests; all dynamic curl options enter through stdin, never argv or a file.
    static func configuration(settings: FTPSettings) throws -> String {
        func hasControl(_ value: String) -> Bool {
            value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }
        guard !hasControl(settings.host) else {
            throw FTPConnectionTestError.invalidSettings("FTP 主机不能包含控制字符。")
        }
        let host = settings.host.trimmingCharacters(in: .whitespaces)
        guard validHost(host), (1...65535).contains(settings.port) else {
            throw FTPConnectionTestError.invalidSettings("请填写有效的 FTP 主机和端口；主机不需要 ftp:// 前缀。")
        }
        guard !settings.username.isEmpty else {
            throw FTPConnectionTestError.invalidSettings("请填写 FTP 用户名。")
        }
        guard !settings.username.contains(":"), !hasControl(settings.username), !hasControl(settings.password) else {
            throw FTPConnectionTestError.invalidSettings("FTP 用户名不能包含冒号，凭据不能包含控制字符。")
        }
        let segments = settings.directory.split(separator: "/").map(String.init)
        guard !hasControl(settings.directory), !settings.directory.contains("\\"), !segments.contains("..") else {
            throw FTPConnectionTestError.invalidSettings("FTP 目录不能包含控制字符、反斜杠或上级目录路径。")
        }
        var components = URLComponents()
        components.scheme = "ftp"
        components.host = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        components.port = settings.port
        components.path = "/"
        guard let url = components.url?.absoluteString else {
            throw FTPConnectionTestError.invalidSettings("FTP 地址无效。")
        }
        let directory = "/" + segments.joined(separator: "/")
        // HEAD on a directory URL needs no data channel. CWD is checked explicitly and curl aborts on failure.
        let config = "user = \(quote(settings.username + ":" + settings.password))\nurl = \(quote(url))\nquote = \(quote("CWD " + directory))\n"
        guard config.utf8.count <= 16_384 else {
            throw FTPConnectionTestError.invalidSettings("FTP 配置内容过长，请检查凭据和目录。")
        }
        return config
    }

    private static func quote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func validHost(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 253 else { return false }
        if value.contains(":") {
            var raw = value
            if raw.hasPrefix("[") && raw.hasSuffix("]") { raw = String(raw.dropFirst().dropLast()) }
            var address = in6_addr()
            return raw.withCString { inet_pton(AF_INET6, $0, &address) } == 1
        }
        let host = value.hasSuffix(".") ? String(value.dropLast()) : value
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        let alphaNumeric = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        let allowed = alphaNumeric.union(CharacterSet(charactersIn: "-"))
        return labels.allSatisfy { label in
            guard !label.isEmpty, label.utf8.count <= 63,
                  let first = label.unicodeScalars.first, let last = label.unicodeScalars.last,
                  alphaNumeric.contains(first), alphaNumeric.contains(last) else { return false }
            return label.unicodeScalars.allSatisfy { allowed.contains($0) }
        }
    }
}
