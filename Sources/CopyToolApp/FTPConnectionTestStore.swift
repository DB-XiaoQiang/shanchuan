import SwiftUI
import CopyToolCore

/// 使用设置窗口的当前输入，不回退到此前保存的端口或凭据。
struct FTPConnectionTestInput: Equatable, Sendable {
    var host: String
    var portText: String
    var username: String
    var password: String
    var directory: String

    func settings() throws -> FTPSettings {
        guard !host.isEmpty,
              !host.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }) else {
            throw FTPConnectionTestError.invalidSettings("请填写不含空白字符的 FTP 主机名或 IP。")
        }
        guard !portText.isEmpty,
              portText.utf8.allSatisfy({ (48...57).contains($0) }),
              let port = Int(portText), (1...65535).contains(port) else {
            throw FTPConnectionTestError.invalidSettings("FTP 端口须为 1–65535 的十进制数字。")
        }
        guard directory.hasPrefix("/") else {
            throw FTPConnectionTestError.invalidSettings("FTP 目标目录须以 / 开头；服务器根目录请填写 /。")
        }
        return FTPSettings(host: host, port: port, username: username,
                           password: password, directory: directory)
    }
}

protocol FTPConnectionTesting: Sendable {
    func test(settings: FTPSettings) throws
    func cancel()
}

extension FTPConnectionTest: FTPConnectionTesting {}

/// 每次点击使用独立测试实例；修改输入或关窗后忽略旧实例的迟到结果。
@MainActor final class FTPConnectionTestStore: ObservableObject {
    enum State: Equatable {
        case idle, testing, success, failed(String)

        var text: String {
            switch self {
            case .idle: return ""
            case .testing: return "正在测试 FTP 连接…"
            case .success: return "连接成功，已登录且目标目录可访问。"
            case .failed(let message): return message
            }
        }
    }

    @Published private(set) var state = State.idle
    var isTesting: Bool { state == .testing }

    private var latestInput: FTPConnectionTestInput?
    private var generation = UUID()
    private var activeTest: (any FTPConnectionTesting)?
    private let makeTest: @Sendable () -> any FTPConnectionTesting

    init(makeTest: @escaping @Sendable () -> any FTPConnectionTesting = { FTPConnectionTest() }) {
        self.makeTest = makeTest
    }

    func test(input: FTPConnectionTestInput) {
        guard !isTesting else { return }
        latestInput = input
        let settings: FTPSettings
        do { settings = try input.settings() }
        catch {
            state = .failed(Self.safeErrorMessage(error, password: input.password))
            return
        }
        let test = makeTest()
        let id = UUID()
        generation = id
        activeTest = test
        state = .testing
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let outcome: Outcome
            do { try test.test(settings: settings); outcome = .success }
            catch FTPConnectionTestError.cancelled { outcome = .cancelled }
            catch { outcome = .failed(Self.safeErrorMessage(error, password: settings.password)) }
            Task { @MainActor [weak self] in
                self?.complete(outcome, generation: id)
            }
        }
    }

    func inputChanged(_ input: FTPConnectionTestInput) {
        guard latestInput != input else { return }
        cancel()
        latestInput = input
    }

    func cancel() {
        generation = UUID()
        activeTest?.cancel()
        activeTest = nil
        state = .idle
    }

    private enum Outcome: Sendable {
        case success, cancelled, failed(String)
    }

    private func complete(_ outcome: Outcome, generation id: UUID) {
        guard generation == id, isTesting else { return }
        activeTest = nil
        switch outcome {
        case .success: state = .success
        case .cancelled: state = .idle
        case .failed(let message): state = .failed(message)
        }
    }

    private nonisolated static func safeErrorMessage(_ error: Error, password: String) -> String {
        // 仅显示 Core 定义的错误，第三方/系统错误文本可能带出服务器回显或凭据。
        guard let connectionError = error as? FTPConnectionTestError else {
            return "FTP 连接测试失败，请检查服务状态和配置。"
        }
        var message = connectionError.errorDescription ?? "FTP 连接测试失败。"
        if !password.isEmpty { message = message.replacingOccurrences(of: password, with: "[已隐藏]") }
        let scalars = message.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        return String(String(String.UnicodeScalarView(scalars)).prefix(500))
    }

    deinit { activeTest?.cancel() }
}
