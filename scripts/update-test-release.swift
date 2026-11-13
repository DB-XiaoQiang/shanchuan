import Foundation
import CryptoKit

// 独立测试通道使用临时签名材料，任何生产签名密钥都不在此工具的输入范围内。
enum TestReleaseError: Error, LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}

let fm = FileManager.default
func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw TestReleaseError.invalid(message) }
}
func write(_ bytes: Data, to url: URL, secret: Bool = false) throws {
    try require(!fm.fileExists(atPath: url.path), "拒绝覆盖已有测试签名材料或发行文件：\(url.lastPathComponent)")
    try bytes.write(to: url, options: .atomic)
    try fm.setAttributes([.posixPermissions: secret ? 0o600 : 0o644], ofItemAtPath: url.path)
}
func text(_ value: String, to url: URL, secret: Bool = false) throws {
    try write(Data(value.utf8), to: url, secret: secret)
}
func readSecret(_ url: URL) throws -> Data {
    let attributes = try fm.attributesOfItem(atPath: url.path)
    let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777
    try require(permissions & 0o077 == 0, "测试私钥文件必须仅当前用户可读写。")
    return try Data(contentsOf: url)
}
func sha256(_ url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
}
func escapeXML(_ value: String) -> String {
    value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
}

do {
    let args = Array(CommandLine.arguments.dropFirst())
    try require(!args.isEmpty, "用法：update-test-release.swift keys <空目录> 或 release <密钥目录> <目标app> <ZIP> <新发行目录>")
    if args[0] == "keys" {
        try require(args.count == 2, "keys 需要一个空目录。")
        let directory = URL(fileURLWithPath: args[1], isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try require(try fm.contentsOfDirectory(atPath: directory.path).isEmpty, "测试签名材料目录必须为空。")
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let manifest = P256.Signing.PrivateKey()
        let sparkle = Curve25519.Signing.PrivateKey()
        try text(manifest.pemRepresentation, to: directory.appendingPathComponent("manifest-private-key.pem"), secret: true)
        try text(manifest.publicKey.pemRepresentation, to: directory.appendingPathComponent("manifest-public-key.pem"))
        try text(sparkle.rawRepresentation.base64EncodedString(), to: directory.appendingPathComponent("sparkle-private-seed"), secret: true)
        try text(sparkle.publicKey.rawRepresentation.base64EncodedString(), to: directory.appendingPathComponent("sparkle-public-key.txt"))
        print("已生成独立测试签名材料；私钥未输出，也未写入钥匙串。")
    } else if args[0] == "release" {
        try require(args.count == 5, "release 需要密钥目录、目标 app、ZIP 和新发行目录。")
        let keys = URL(fileURLWithPath: args[1], isDirectory: true)
        let app = URL(fileURLWithPath: args[2], isDirectory: true)
        let archive = URL(fileURLWithPath: args[3])
        let output = URL(fileURLWithPath: args[4], isDirectory: true)
        try require(!fm.fileExists(atPath: output.path), "发行目录已存在，拒绝覆盖。")
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any] ?? [:]
        try require(info["CFBundleIdentifier"] as? String == "local.copytool.update-test" && info["ShanchuanUpdateTest"] as? Bool == true,
                    "只允许打包独立更新测试应用。")
        try require(info["CFBundleShortVersionString"] as? String == "0.1.4", "目标测试版本必须为已确认的 0.1.4。")
        try require(info["ShanchuanUpdateTestTargetVersion"] as? String == "0.1.4", "目标包的独立测试通道配置不匹配。")
        let build = info["CFBundleVersion"] as? String ?? ""
        try require(Int(build).map { $0 > 1003 } == true, "目标构建号必须大于旧测试构建 1003。")
        try require(archive.lastPathComponent == "ShanchuanUpdateTest-macos-arm64.zip", "目标 ZIP 名称不符合测试通道约定。")
        let seedText = String(decoding: try readSecret(keys.appendingPathComponent("sparkle-private-seed")), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let seed = Data(base64Encoded: seedText) else { throw TestReleaseError.invalid("测试 EdDSA 私钥格式错误。") }
        let sparkle = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        try require(info["SUPublicEDKey"] as? String == sparkle.publicKey.rawRepresentation.base64EncodedString(), "目标包未内置同一测试 Sparkle 公钥。")
        let manifest = try P256.Signing.PrivateKey(pemRepresentation: String(decoding: try readSecret(keys.appendingPathComponent("manifest-private-key.pem")), as: UTF8.self))
        let embeddedManifestKey = try String(contentsOf: app.appendingPathComponent("Contents/Resources/update-public-key.pem"), encoding: .utf8)
        try require(try P256.Signing.PublicKey(pemRepresentation: embeddedManifestKey).rawRepresentation == manifest.publicKey.rawRepresentation,
                    "目标包未内置同一测试清单公钥。")
        let archiveBytes = try Data(contentsOf: archive, options: .mappedIfSafe)
        let signature = try sparkle.signature(for: archiveBytes).base64EncodedString()
        let base = "https://github.com/DB-XiaoQiang/shanchuan/releases/download/update-test-v0.1.4/"
        let appcast = """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel><title>闪传独立更新测试</title><item>
            <title>闪传更新测试 0.1.4</title>
            <description>仅用于独立测试应用的 0.1.3 → 0.1.4 更新，不访问正式配置或 FTP。</description>
            <sparkle:version>\(escapeXML(build))</sparkle:version>
            <sparkle:shortVersionString>0.1.4</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
            <enclosure url="\(base + archive.lastPathComponent)" length="\(archiveBytes.count)" type="application/octet-stream" sparkle:edSignature="\(signature)"/>
          </item></channel>
        </rss>
        """
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        let targetArchive = output.appendingPathComponent(archive.lastPathComponent)
        try fm.copyItem(at: archive, to: targetArchive)
        let feed = output.appendingPathComponent("appcast.xml")
        try text(appcast, to: feed)
        func asset(_ file: URL, kind: String) throws -> [String: Any] {
            ["platform": "macos", "arch": "arm64", "kind": kind, "name": file.lastPathComponent,
             "size": try fm.attributesOfItem(atPath: file.path)[.size] as? NSNumber ?? 0,
             "sha256": try sha256(file)]
        }
        let object: [String: Any] = ["schemaVersion": 1, "product": "Shanchuan", "channel": "test", "version": "0.1.4",
            "releaseNotes": "独立更新测试 0.1.3 → 0.1.4。使用测试签名和独立数据目录，不访问真实 FTP。确认后由 Sparkle 安装并重启测试应用。",
            "assets": try [asset(targetArchive, kind: "sparkle-zip"), asset(feed, kind: "appcast")]]
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
        try write(bytes, to: output.appendingPathComponent("update-manifest.json"))
        try write(manifest.signature(for: bytes).derRepresentation, to: output.appendingPathComponent("update-manifest.sig"))
        print("已生成独立测试 ZIP、appcast 和签名清单；未生成正式通道文件。")
    } else {
        throw TestReleaseError.invalid("未知操作。")
    }
} catch {
    fputs("独立测试发行准备失败：\(error.localizedDescription)\n", stderr)
    exit(1)
}
