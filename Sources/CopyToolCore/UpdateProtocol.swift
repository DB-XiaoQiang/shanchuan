import Foundation
import CryptoKit

public enum UpdateFailure: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let reason) = self { return reason }; return nil }
}

public struct ReleaseVersion: Comparable, Equatable, Sendable {
    public let parts: [Int]
    public init(_ value: String) throws {
        let fields = value.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 3 else { throw UpdateFailure.invalid("版本号须为三段数字。") }
        let values = fields.compactMap { field -> Int? in
            guard !field.isEmpty, field.utf8.allSatisfy({ (48...57).contains($0) }),
                  field.count == 1 || field.first != "0", let number = Int(field), number <= 999999 else { return nil }
            return number
        }
        guard values.count == 3 else { throw UpdateFailure.invalid("版本号无效。") }
        parts = values
    }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }
}

public struct ReleaseAsset: Codable, Equatable, Sendable {
    public let platform: String
    public let arch: String
    public let kind: String
    public let name: String
    public let size: Int64
    public let sha256: String
}

public struct ReleaseManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let product: String
    public let channel: String
    public let version: String
    public let releaseNotes: String
    public let assets: [ReleaseAsset]
    public func asset(platform: String, arch: String, kind: String) -> ReleaseAsset? {
        assets.first { $0.platform == platform && $0.arch == arch && $0.kind == kind }
    }
}

public struct VerifiedRelease: Sendable {
    public let manifest: ReleaseManifest
    public let bytes: Data
    public let signature: Data
    public var identity: String { UpdateVerifier.sha256(bytes) }
    public init(manifest: ReleaseManifest, bytes: Data, signature: Data) {
        self.manifest = manifest; self.bytes = bytes; self.signature = signature
    }
}

public enum UpdateVerifier {
    public static let maximumManifestBytes = 256 * 1024
    public static let maximumAssetBytes: Int64 = 2 * 1024 * 1024 * 1024
    public static func sha256(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    public static func verify(manifest bytes: Data, signature: Data, publicKeyPEM: String,
                              expectedChannel: String = "stable") throws -> VerifiedRelease {
        guard !bytes.isEmpty, bytes.count <= maximumManifestBytes, signature.count <= 256 else {
            throw UpdateFailure.invalid("更新清单或签名大小无效。")
        }
        let key = try P256.Signing.PublicKey(pemRepresentation: publicKeyPEM)
        let signed = try P256.Signing.ECDSASignature(derRepresentation: signature)
        guard key.isValidSignature(signed, for: bytes) else { throw UpdateFailure.invalid("更新清单签名不正确。") }
        let manifest = try JSONDecoder().decode(ReleaseManifest.self, from: bytes)
        guard ["stable", "test"].contains(expectedChannel),
              manifest.schemaVersion == 1, manifest.product == "Shanchuan", manifest.channel == expectedChannel,
              !manifest.assets.isEmpty, manifest.assets.count <= 32, manifest.releaseNotes.utf8.count <= 65536 else {
            throw UpdateFailure.invalid("更新清单产品、通道或协议不匹配。")
        }
        _ = try ReleaseVersion(manifest.version)
        var names = Set<String>(); var kinds = Set<String>()
        let windowsKinds: Set<String> = ["velopack-full", "velopack-feed", "setup", "portable"]
        let macosKinds: Set<String> = ["sparkle-zip", "dmg", "appcast"]
        for asset in manifest.assets {
            let supported = (asset.platform == "windows" && asset.arch == "x64" && windowsKinds.contains(asset.kind)) ||
                (asset.platform == "macos" && asset.arch == "arm64" && macosKinds.contains(asset.kind))
            guard supported, validName(asset.name), asset.size > 0,
                  asset.size <= maximumAssetBytes, asset.sha256.count == 64,
                  asset.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  names.insert(asset.name.lowercased()).inserted,
                  kinds.insert("\(asset.platform)/\(asset.arch)/\(asset.kind)").inserted else {
                throw UpdateFailure.invalid("更新附件名称、平台、大小或摘要无效。")
            }
        }
        return VerifiedRelease(manifest: manifest, bytes: bytes, signature: signature)
    }
    public static func validName(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 180, value.first?.isASCII == true,
              value.first?.isLetter == true || value.first?.isNumber == true else { return false }
        return value.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0) }
    }
    public static func verify(file: URL, asset: ReleaseAsset) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard (attributes[.type] as? FileAttributeType) == .typeRegular,
              (attributes[.size] as? NSNumber)?.int64Value == asset.size else {
            throw UpdateFailure.invalid("更新附件大小不匹配：\(asset.name)")
        }
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        var digest = SHA256()
        while let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty { digest.update(data: bytes) }
        let actual = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == asset.sha256 else { throw UpdateFailure.invalid("更新附件摘要不匹配：\(asset.name)") }
    }
    public static func verifyWindowsFeed(_ release: VerifiedRelease, directory: URL) throws {
        guard let full = release.manifest.asset(platform: "windows", arch: "x64", kind: "velopack-full"),
              let feed = release.manifest.asset(platform: "windows", arch: "x64", kind: "velopack-feed"),
              feed.name == "releases.win-x64.json" else {
            throw UpdateFailure.invalid("发行版缺少 Windows 完整更新包。")
        }
        try verify(file: directory.appendingPathComponent(full.name), asset: full)
        try verify(file: directory.appendingPathComponent(feed.name), asset: feed)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent(feed.name)))
        guard let dictionary = object as? [String: Any], let assets = dictionary["Assets"] as? [[String: Any]],
              assets.count == 1, let target = assets.first,
              target["PackageId"] as? String == "Shanchuan",
              target["FileName"] as? String == full.name,
              target["Version"] as? String == release.manifest.version,
              target["Type"] as? String == "Full",
              (target["Size"] as? NSNumber)?.int64Value == full.size,
              (target["SHA256"] as? String)?.lowercased() == full.sha256 else {
            throw UpdateFailure.invalid("Windows 更新索引与已签名发行清单不一致。")
        }
    }
}

/// Shared by business jobs and one-file update relay steps. Waiting business jobs win.
public final class UpdateTransferGate: @unchecked Sendable {
    public static let shared = UpdateTransferGate()
    private let condition = NSCondition()
    private var occupied = false
    private var waitingBusiness = 0
    public init() {}
    public func beginBusiness() {
        condition.lock(); waitingBusiness += 1
        while occupied { condition.wait() }
        waitingBusiness -= 1; occupied = true; condition.unlock()
    }
    public func beginUpdate() {
        condition.lock()
        while occupied || waitingBusiness > 0 { condition.wait() }
        occupied = true; condition.unlock()
    }
    public func end() { condition.lock(); occupied = false; condition.broadcast(); condition.unlock() }
}

public struct UpdateCheckSchedule: Codable, Equatable, Sendable {
    public var completedWindow: Date?
    public var retryAfter: Date?
    public var failureCount = 0
    public init() {}
    public static func window(at now: Date, calendar: Calendar = .current) -> Date {
        let day = calendar.startOfDay(for: now)
        let today = calendar.date(bySettingHour: 1, minute: 0, second: 0, of: day)!
        return now >= today ? today : calendar.date(byAdding: .day, value: -1, to: today)!
    }
    public func isDue(at now: Date, calendar: Calendar = .current) -> Bool {
        if let retryAfter { return now >= retryAfter }
        return completedWindow == nil || completedWindow! < Self.window(at: now, calendar: calendar)
    }
    public mutating func succeeded(at now: Date, calendar: Calendar = .current) {
        completedWindow = Self.window(at: now, calendar: calendar); retryAfter = nil; failureCount = 0
    }
    public mutating func failed(at now: Date) {
        let minutes = [1, 5, 15, 60][min(failureCount, 3)]
        failureCount += 1; retryAfter = now.addingTimeInterval(Double(minutes * 60))
    }
}
