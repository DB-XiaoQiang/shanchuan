import AppKit
import Combine
import CopyToolCore

private final class BoundedUpdateDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let maximum: Int64
    init(maximum: Int64) { self.maximum = maximum }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > maximum || totalBytesExpectedToWrite > maximum { downloadTask.cancel() }
    }
}

struct UpdatePersistentState: Codable {
    var schedule = UpdateCheckSchedule()
    var candidateVersion: String?
    var candidateIdentity: String?
    var highestVersion: String?
    var relayed: [String] = []
    var relayRetryAfter: Date?
    var relayFailures = 0
    var lastCheckCompletedAt: Date?
}

enum UpdateHTTPFailure: LocalizedError {
    case status(Int)
    var errorDescription: String? {
        switch self {
        case .status(401): return L10n.text("更新服务要求访问权限（HTTP 401）。")
        case .status(403): return L10n.text("更新服务拒绝访问（HTTP 403），请稍后重试。")
        case .status(429): return L10n.text("更新检查过于频繁（HTTP 429），请稍后重试。")
        case .status(let code) where code >= 500: return L10n.format("更新服务暂时不可用（HTTP %@），请稍后重试。", String(describing: code))
        case .status(let code): return L10n.format("更新服务返回 HTTP %@。", String(describing: code))
        }
    }
}

private struct GitHubLatestRelease: Decodable {
    let tag_name: String
    let draft: Bool
    let prerelease: Bool
}

/// All automatic work is data-only; Sparkle is not started until the user asks to install.
@MainActor final class UpdateCoordinator: ObservableObject {
    static let repository = "https://github.com/DB-XiaoQiang/shanchuan"
    static let downloadPage = URL(string: repository + "/releases")!
    @Published private(set) var status = L10n.text("等待检查更新")
    @Published private(set) var relayStatus = ""
    @Published private(set) var candidateVersion: String?
    @Published private(set) var releaseNotes = ""
    @Published private(set) var isChecking = false
    @Published private(set) var isRelaying = false
    @Published private(set) var waitingForInstallation = false
    @Published private(set) var lastCheckCompletedAt: Date?
    var currentVersion: String
    var ftpSettings: () -> FTPSettings? = { nil }
    var businessIsBusy: () -> Bool = { false }
    var install: ((String) -> Bool)?
    var installationMayBegin: (() -> Void)?
    var writeLog: ((String, Bool) -> Void)?
    private let root: URL
    private let publicKey: String?
    private let channel: UpdateChannel
    private var state: UpdatePersistentState
    private var release: VerifiedRelease?
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var enabled = false
    private let session: URLSession
    private let dataLoader: (@Sendable (URL, Int64) async throws -> Data)?
    private let testUpload: (@Sendable (URL, String, FTPSettings) async throws -> Void)?
    private let relayQueue = DispatchQueue(label: "local.copytool.update-relay", qos: .utility)
    private var relayTask: Task<Void, Never>?
    private var lastEndpoint = ""
    private var started = false

    init(root: URL? = nil, currentVersion: String? = nil, publicKey: String? = nil, session: URLSession? = nil,
         channel: UpdateChannel = .production,
         dataLoader: (@Sendable (URL, Int64) async throws -> Data)? = nil,
         upload: (@Sendable (URL, String, FTPSettings) async throws -> Void)? = nil) {
        self.root = (root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CopyToolIndependent")).appendingPathComponent("Updates", isDirectory: true)
        self.currentVersion = currentVersion ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        self.channel = channel
        self.publicKey = publicKey ?? Bundle.main.url(forResource: "update-public-key", withExtension: "pem").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        self.session = session ?? URLSession(configuration: .ephemeral)
        self.dataLoader = dataLoader; self.testUpload = upload
        state = (try? Data(contentsOf: self.root.appendingPathComponent("state.json")))
            .flatMap { try? JSONDecoder().decode(UpdatePersistentState.self, from: $0) } ?? UpdatePersistentState()
        lastCheckCompletedAt = state.lastCheckCompletedAt
        candidateVersion = nil
        if self.publicKey == nil { status = L10n.text("此构建未配置更新验签公钥") }
        if channel.isTest { relayStatus = L10n.text("独立测试通道：仅更新测试应用，不转发 FTP") }
        if let error = channel.configurationError { status = error }
    }
    deinit {
        timer?.invalidate()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        relayTask?.cancel()
    }
    var displayedVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? L10n.text("开发构建") }
    var canInstall: Bool { candidateVersion != nil && !waitingForInstallation }
    var canCheck: Bool { !isChecking && !waitingForInstallation && publicKey != nil && channel.configurationError == nil }
    var isBusy: Bool { isRelaying || waitingForInstallation }

    func start() {
        guard !started else { return }; started = true
        guard publicKey != nil, channel.configurationError == nil else { return }
        enabled = true
        do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { status = L10n.format("更新缓存不可用：%@", String(describing: error.localizedDescription)); return }
        // Remove only our abandoned scratch downloads; verified version caches remain separate.
        if let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "download" && UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil {
                try? FileManager.default.removeItem(at: file)
            }
        }
        restoreCandidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()
    }
    func check() { guard canCheck else { return }; Task { await checkNow() } }
    func checkNow() async { await performCheck(manual: true) }
    func tick(now: Date = Date()) {
        guard enabled, !waitingForInstallation else { return }
        if state.schedule.isDue(at: now) && !isChecking { Task { await performCheck() } }
        guard channel.allowsRelay else { return }
        let endpoint = ftpSettings().map(Self.endpointIdentity) ?? ""
        let changed = endpoint != lastEndpoint
        if changed { lastEndpoint = endpoint; state.relayRetryAfter = nil }
        if !isChecking && !isRelaying && (state.relayRetryAfter == nil || now >= state.relayRetryAfter!) { beginRelay() }
    }
    func retry() {
        state.relayRetryAfter = nil; state.relayFailures = 0
        check()
        if channel.allowsRelay && !isRelaying { beginRelay() }
    }
    private func save() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = root.appendingPathComponent("state.json")
        try JSONEncoder().encode(state).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    private func restoreCandidate() {
        guard let version = state.candidateVersion, let identity = state.candidateIdentity, let publicKey else { return }
        do {
            let directory = cacheDirectory(version: version, identity: identity)
            let verified = try UpdateVerifier.verify(manifest: Data(contentsOf: directory.appendingPathComponent("update-manifest.json")),
                signature: Data(contentsOf: directory.appendingPathComponent("update-manifest.sig")), publicKeyPEM: publicKey,
                expectedChannel: channel.expectedManifestChannel)
            try channel.validateManifestVersion(verified.manifest.version)
            guard verified.identity == identity, verified.manifest.version == version else { return }
            let target = try ReleaseVersion(version)
            guard target >= (try ReleaseVersion(currentVersion)) else { return }
            if let highest = state.highestVersion, target < (try ReleaseVersion(highest)) { return }
            for asset in selectedAssets(verified) { try UpdateVerifier.verify(file: directory.appendingPathComponent(asset.name), asset: asset) }
            if channel.requiresWindowsAssets { try UpdateVerifier.verifyWindowsFeed(verified, directory: directory) }
            release = verified
            showCandidate(verified)
        } catch { status = L10n.text("上次更新缓存需要重新下载") }
    }
    private func selectedAssets(_ release: VerifiedRelease) -> [ReleaseAsset] {
        release.manifest.assets.filter {
            (channel.requiresWindowsAssets && $0.platform == "windows" && $0.arch == "x64" && ["velopack-full", "velopack-feed"].contains($0.kind)) ||
            ($0.platform == "macos" && $0.arch == "arm64" && ["sparkle-zip", "appcast"].contains($0.kind))
        }
    }
    private func cacheDirectory(version: String, identity: String) -> URL {
        root.appendingPathComponent("cache", isDirectory: true).appendingPathComponent(version, isDirectory: true).appendingPathComponent(identity, isDirectory: true)
    }
    private func showCandidate(_ verified: VerifiedRelease) {
        if let current = try? ReleaseVersion(currentVersion), let latest = try? ReleaseVersion(verified.manifest.version), latest > current,
           verified.manifest.asset(platform: "macos", arch: "arm64", kind: "sparkle-zip") != nil,
           verified.manifest.asset(platform: "macos", arch: "arm64", kind: "appcast") != nil {
            candidateVersion = verified.manifest.version; releaseNotes = verified.manifest.releaseNotes
            status = L10n.format("新版本 %@ 已下载，可安装", String(describing: verified.manifest.version))
        } else { candidateVersion = nil; status = L10n.text("当前已是最新版本") }
    }
    private func performCheck(manual: Bool = false) async {
        guard !isChecking, !waitingForInstallation, let publicKey, channel.configurationError == nil else { return }
        isChecking = true; status = L10n.text("正在检查更新…")
        if manual { writeLog?(channel.isTest ? L10n.text("开始手动检查独立测试更新") : L10n.text("开始手动检查正式更新"), false) }
        var failed = false
        defer {
            let completedAt = Date()
            lastCheckCompletedAt = completedAt
            state.lastCheckCompletedAt = completedAt
            try? save()
            isChecking = false
            if manual { writeLog?(L10n.text("手动检查完成：") + status, failed) }
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let metadataBytes: Data
            do {
                metadataBytes = try await fetch(channel.metadataURL, maximum: 2 * 1024 * 1024)
            } catch UpdateHTTPFailure.status(404) {
                state.schedule.succeeded(at: Date()); try save()
                if let release { showCandidate(release) } else { status = channel.noReleaseStatus }
                return
            }
            let metadata = try JSONDecoder().decode(GitHubLatestRelease.self, from: metadataBytes)
            let version = try channel.version(fromTag: metadata.tag_name, draft: metadata.draft, prerelease: metadata.prerelease)
            let latest = try ReleaseVersion(version)
            if let highest = state.highestVersion, latest < (try ReleaseVersion(highest)) { throw UpdateFailure.invalid(L10n.text("拒绝回放旧版本更新。")) }
            guard latest >= (try ReleaseVersion(currentVersion)) else { throw UpdateFailure.invalid(L10n.text("拒绝低于当前安装版本的发行包。")) }
            let base = channel.assetBase(version: version)
            let bytes = try await fetch(base.appendingPathComponent("update-manifest.json"), maximum: Int64(UpdateVerifier.maximumManifestBytes))
            let signature = try await fetch(base.appendingPathComponent("update-manifest.sig"), maximum: 256)
            let verified = try UpdateVerifier.verify(manifest: bytes, signature: signature, publicKeyPEM: publicKey,
                expectedChannel: channel.expectedManifestChannel)
            guard verified.manifest.version == version else { throw UpdateFailure.invalid(L10n.text("GitHub 标签与签名清单版本不一致。")) }
            try channel.validateManifestVersion(verified.manifest.version)
            guard (!channel.requiresWindowsAssets ||
                    (verified.manifest.asset(platform: "windows", arch: "x64", kind: "velopack-full") != nil &&
                     verified.manifest.asset(platform: "windows", arch: "x64", kind: "velopack-feed") != nil)),
                  verified.manifest.asset(platform: "macos", arch: "arm64", kind: "sparkle-zip") != nil,
                  verified.manifest.asset(platform: "macos", arch: "arm64", kind: "appcast") != nil else {
                throw UpdateFailure.invalid(L10n.text("正式发行版缺少平台更新附件。"))
            }
            let directory = cacheDirectory(version: version, identity: verified.identity)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for asset in selectedAssets(verified) {
                let destination = directory.appendingPathComponent(asset.name)
                if (try? UpdateVerifier.verify(file: destination, asset: asset)) != nil { continue }
                status = L10n.format("正在下载更新：%@", String(describing: asset.name))
                let temporary = try await download(base.appendingPathComponent(asset.name), maximum: asset.size)
                defer { try? FileManager.default.removeItem(at: temporary) }
                try UpdateVerifier.verify(file: temporary, asset: asset)
                if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
            if channel.requiresWindowsAssets { try UpdateVerifier.verifyWindowsFeed(verified, directory: directory) }
            try bytes.write(to: directory.appendingPathComponent("update-manifest.json"), options: .atomic)
            try signature.write(to: directory.appendingPathComponent("update-manifest.sig"), options: .atomic)
            release = verified; state.candidateVersion = version; state.candidateIdentity = verified.identity; state.highestVersion = version
            state.schedule.succeeded(at: Date()); try save()
            showCandidate(verified)
            if !manual { writeLog?(L10n.format("已验证发行版 %@，更新已缓存", String(describing: version)), false) }
            beginRelay()
        } catch {
            failed = true
            status = L10n.format("检查或下载更新失败：%@", String(describing: error.localizedDescription))
            state.schedule.failed(at: Date()); try? save()
            if !manual { writeLog?(status, true) }
        }
    }
    private func fetch(_ url: URL, maximum: Int64) async throws -> Data {
        let file = try await download(url, maximum: maximum); defer { try? FileManager.default.removeItem(at: file) }
        return try Data(contentsOf: file)
    }
    private func download(_ url: URL, maximum: Int64) async throws -> URL {
        if let dataLoader {
            let bytes = try await dataLoader(url, maximum)
            guard bytes.count <= maximum else { throw UpdateFailure.invalid(L10n.text("更新响应超过大小上限。")) }
            let temporary = root.appendingPathComponent(UUID().uuidString + ".download")
            try bytes.write(to: temporary, options: .atomic)
            return temporary
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
        request.setValue("Shanchuan-Updater", forHTTPHeaderField: "User-Agent")
        let delegate = BoundedUpdateDownload(maximum: maximum)
        let (file, response) = try await session.download(for: request, delegate: delegate)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            try? FileManager.default.removeItem(at: file)
            throw UpdateHTTPFailure.status(http.statusCode)
        }
        guard response is HTTPURLResponse, response.url?.scheme == "https",
              (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? Int64.max <= maximum else {
            try? FileManager.default.removeItem(at: file)
            throw UpdateFailure.invalid(L10n.text("更新下载响应或大小无效。"))
        }
        let temporary = root.appendingPathComponent(UUID().uuidString + ".download")
        try FileManager.default.moveItem(at: file, to: temporary)
        return temporary
    }
    private static func endpointIdentity(_ settings: FTPSettings) -> String {
        UpdateVerifier.sha256(Data("\(settings.host.lowercased()):\(settings.port)/\(settings.username)/\(settings.directory)".utf8))
    }
    private func beginRelay() {
        guard channel.allowsRelay else { return }
        guard !isRelaying, !waitingForInstallation, let verified = release else { return }
        guard let settings = ftpSettings(), !settings.host.isEmpty else { relayStatus = L10n.text("等待配置 FTP 后转发更新"); return }
        let identity = Self.endpointIdentity(settings) + ":" + verified.manifest.version + ":" + verified.identity
        guard !state.relayed.contains(identity) else { relayStatus = L10n.text("Windows 更新已投递（不代表内网已安装）"); return }
        isRelaying = true; relayStatus = L10n.text("等待空闲后转发 Windows 更新")
        relayTask = Task {
            defer { isRelaying = false; relayTask = nil }
            do {
                while businessIsBusy() { try await Task.sleep(nanoseconds: 500_000_000) }
                let directory = cacheDirectory(version: verified.manifest.version, identity: verified.identity)
                try UpdateVerifier.verifyWindowsFeed(verified, directory: directory)
                let assets = verified.manifest.assets.filter { $0.platform == "windows" && $0.arch == "x64" && ["velopack-full", "velopack-feed"].contains($0.kind) }
                let names = assets.map(\.name) + ["update-manifest.json", "update-manifest.sig"]
                let batch = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
                var destination = settings
                destination.directory = settings.directory.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                destination.directory = "/" + destination.directory + (destination.directory.isEmpty ? "" : "/") + "shanchuan_updates/stable/win-x64/\(verified.manifest.version)/\(batch)"
                for name in names {
                    try Task.checkCancellation()
                    while businessIsBusy() { try await Task.sleep(nanoseconds: 500_000_000) }
                    relayStatus = L10n.format("正在转发 Windows 更新：%@", String(describing: name))
                    let file = directory.appendingPathComponent(name)
                    let frozenDestination = destination
                    if let testUpload { try await testUpload(file, name, frozenDestination); continue }
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        relayQueue.async {
                            UpdateTransferGate.shared.beginUpdate(); defer { UpdateTransferGate.shared.end() }
                            do {
                                try FTPTransfer().upload(file: file, remoteName: name, settings: frozenDestination, progress: { _ in })
                                continuation.resume()
                            } catch { continuation.resume(throwing: error) }
                        }
                    }
                }
                state.relayed.append(identity); state.relayed = Array(state.relayed.suffix(128)); state.relayRetryAfter = nil; state.relayFailures = 0
                try save(); relayStatus = L10n.text("Windows 更新已投递（不代表内网已安装）")
                writeLog?(L10n.format("Windows %@ 更新包已投递", String(describing: verified.manifest.version)), false)
            } catch {
                let minutes = [1, 5, 15, 60][min(state.relayFailures, 3)]
                state.relayFailures += 1; state.relayRetryAfter = Date().addingTimeInterval(Double(minutes * 60)); try? save()
                relayStatus = L10n.format("更新转发失败，将重试：%@", String(describing: error.localizedDescription)); writeLog?(relayStatus, true)
            }
        }
    }
    func installationCycleFinished(error: String? = nil) {
        waitingForInstallation = false
        if let error { status = L10n.text("更新安装已停止：") + error }
        else if let release { showCandidate(release) }
    }
    func requestInstall() {
        guard let version = candidateVersion, let verified = release, !waitingForInstallation else { return }
        let alert = NSAlert()
        alert.messageText = channel.isTest ? L10n.format("更新“闪传更新测试”到 %@？", String(describing: version)) : L10n.format("更新闪传到 %@？", String(describing: version))
        alert.informativeText = releaseNotes + (channel.isTest
            ? L10n.text("\n仅替换独立测试应用；正式闪传、配置和 FTP 不受影响。确认后安装并重启测试应用。")
            : L10n.text("\n将等待普通传输和更新转发结束后安装并重启。"))
        alert.addButton(withTitle: L10n.text("更新")); alert.addButton(withTitle: L10n.text("稍后"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        waitingForInstallation = true; status = L10n.text("已确认，等待传输完成后更新")
        Task {
            while businessIsBusy() || isRelaying || isChecking { try? await Task.sleep(nanoseconds: 500_000_000) }
            do {
                let directory = cacheDirectory(version: version, identity: verified.identity)
                for asset in selectedAssets(verified) { try UpdateVerifier.verify(file: directory.appendingPathComponent(asset.name), asset: asset) }
                installationMayBegin?()
                if install?(version) != true { waitingForInstallation = false }
            } catch { status = L10n.format("安装前验证失败：%@", String(describing: error.localizedDescription)); waitingForInstallation = false }
        }
    }
}
