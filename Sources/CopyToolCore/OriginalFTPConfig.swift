import Foundation

public struct ImportedFTPConfiguration: Sendable {
    public let preferences: AppPreferences
    public let password: String

    public init(preferences: AppPreferences, password: String) {
        self.preferences = preferences
        self.password = password
    }
}

/// Imports only the original application's flat FTP settings, without writing either application's data.
public enum OriginalFTPConfig {
    public enum ImportError: Error, LocalizedError, Equatable {
        case unreadableFile
        case invalidEncoding
        case oversizedConfiguration
        case unsupportedSyntax(line: Int)
        case duplicateKey(line: Int)
        case missingField(String)
        case invalidField(String)

        public var errorDescription: String? {
            switch self {
            case .unreadableFile: return L10n.text("无法读取所选原应用配置文件。")
            case .invalidEncoding: return L10n.text("原应用配置必须是有效 UTF-8 文本。")
            case .oversizedConfiguration: return L10n.text("原应用配置文件过大，已停止导入。")
            case .unsupportedSyntax(let line): return L10n.format("原应用配置第 %@ 行包含不支持的 TOML 语法。", String(describing: line))
            case .duplicateKey(let line): return L10n.format("原应用配置第 %@ 行包含重复字段。", String(describing: line))
            case .missingField(let field): return L10n.format("原应用配置缺少 FTP 字段：%@。", String(describing: field))
            case .invalidField(let field): return L10n.format("原应用 FTP 字段无效：%@。", String(describing: field))
            }
        }
    }

    private enum ScalarValue {
        case string(String), integer(Int64), boolean(Bool)
    }

    private static let maximumBytes = 1_048_576

    public static func load(from url: URL, preserving preferences: AppPreferences) throws -> ImportedFTPConfiguration {
        guard url.isFileURL else { throw ImportError.unreadableFile }
        let data: Data
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isReadable == true else { throw ImportError.unreadableFile }
            guard (values.fileSize ?? 0) <= maximumBytes else { throw ImportError.oversizedConfiguration }
            data = try Data(contentsOf: url)
        } catch let error as ImportError { throw error }
        catch { throw ImportError.unreadableFile }
        guard data.count <= maximumBytes else { throw ImportError.oversizedConfiguration }
        guard let text = String(data: data, encoding: .utf8) else { throw ImportError.invalidEncoding }
        return try parse(text, preserving: preferences)
    }

    public static func parse(_ text: String, preserving preferences: AppPreferences) throws -> ImportedFTPConfiguration {
        guard text.utf8.count <= maximumBytes else { throw ImportError.oversizedConfiguration }
        var fields: [String: ScalarValue] = [:]
        for (index, rawLine) in text.components(separatedBy: "\n").enumerated() {
            var line = rawLine
            if line.hasSuffix("\r") { line.removeLast() }
            var parser = LineParser(line, line: index + 1)
            if let (key, value) = try parser.assignment() {
                guard fields[key] == nil else { throw ImportError.duplicateKey(line: index + 1) }
                fields[key] = value
            }
        }

        func string(_ key: String, required: Bool = true) throws -> String? {
            guard let value = fields[key] else {
                if required { throw ImportError.missingField(key) }
                return nil
            }
            guard case .string(let result) = value else { throw ImportError.invalidField(key) }
            return result
        }

        var imported = preferences
        imported.host = try string("ip")!
        imported.username = try string("username")!
        imported.directory = try string("dest")!
        let password = try string("password")!
        guard let port = fields["port"] else { throw ImportError.missingField("port") }
        guard case .integer(let number) = port, (1...65535).contains(number) else { throw ImportError.invalidField("port") }
        imported.port = Int(number)
        if let value = try string("control_file", required: false) { imported.textRemoteName = value }
        if let value = try string("decrypt_prefix", required: false) { imported.decryptPrefix = value }
        if let value = fields["auto_decrypt"] {
            guard case .boolean(let enabled) = value else { throw ImportError.invalidField("auto_decrypt") }
            imported.autoDecrypt = enabled
        }

        guard !imported.host.isEmpty,
              !imported.host.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }),
              !imported.host.contains(where: { "/@?#\\".contains($0) }) else { throw ImportError.invalidField("ip") }
        guard !imported.username.isEmpty, !imported.username.contains(":"), !hasControl(imported.username) else { throw ImportError.invalidField("username") }
        guard !password.isEmpty, !hasControl(password) else { throw ImportError.invalidField("password") }
        guard validDirectory(imported.directory) else { throw ImportError.invalidField("dest") }
        guard validDirectory(imported.decryptPrefix) else { throw ImportError.invalidField("decrypt_prefix") }
        guard !imported.textRemoteName.isEmpty, imported.textRemoteName != ".", imported.textRemoteName != "..",
              !hasControl(imported.textRemoteName), !imported.textRemoteName.contains(where: { ",|/\\".contains($0) }) else {
            throw ImportError.invalidField("control_file")
        }
        return ImportedFTPConfiguration(preferences: imported, password: password)
    }

    private static func hasControl(_ value: String) -> Bool {
        value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    private static func validDirectory(_ value: String) -> Bool {
        value.hasPrefix("/") && !value.split(separator: "/").contains("..") && !value.contains("\\") && !hasControl(value)
    }

    /// A deliberately limited TOML reader: flat bare keys and single-line scalar values only.
    private struct LineParser {
        let source: [Unicode.Scalar]
        let line: Int
        var position = 0

        init(_ source: String, line: Int) { self.source = Array(source.unicodeScalars); self.line = line }
        var current: Unicode.Scalar? { position < source.count ? source[position] : nil }
        var failure: ImportError { .unsupportedSyntax(line: line) }

        mutating func spaces() {
            while current == " " || current == "\t" { position += 1 }
        }

        mutating func assignment() throws -> (String, ScalarValue)? {
            spaces()
            if current == nil || current == "#" { return nil }
            let start = position
            while let c = current, (48...57).contains(c.value) || (65...90).contains(c.value) || (97...122).contains(c.value) || c == "_" || c == "-" { position += 1 }
            guard position > start else { throw failure }
            let key = String(String.UnicodeScalarView(source[start..<position]))
            spaces()
            guard current == "=" else { throw failure }
            position += 1; spaces()
            let value: ScalarValue
            if current == "\"" || current == "'" { value = .string(try quotedString()) }
            else {
                let start = position
                while let c = current, c != " " && c != "\t" && c != "#" { position += 1 }
                let token = String(String.UnicodeScalarView(source[start..<position]))
                if token == "true" { value = .boolean(true) }
                else if token == "false" { value = .boolean(false) }
                else {
                    guard token.range(of: #"^[+-]?(?:0|[1-9](?:_?[0-9])*)$"#, options: .regularExpression) != nil,
                          let number = Int64(token.replacingOccurrences(of: "_", with: "")) else { throw failure }
                    value = .integer(number)
                }
            }
            spaces()
            guard current == nil || current == "#" else { throw failure }
            // Disallow hidden control characters even in ignored comments.
            guard !source.contains(where: { $0.value < 32 && $0 != "\t" || $0.value == 127 }) else { throw failure }
            return (key, value)
        }

        mutating func quotedString() throws -> String {
            guard let quote = current else { throw failure }
            position += 1
            var result = String.UnicodeScalarView()
            while let c = current {
                position += 1
                if c == quote { return String(result) }
                guard c.value >= 32 || c == "\t", c.value != 127 else { throw failure }
                if quote == "\"" && c == "\\" {
                    guard let escaped = current else { throw failure }
                    position += 1
                    switch escaped {
                    case "b": result.append("\u{0008}")
                    case "t": result.append("\t")
                    case "n": result.append("\n")
                    case "f": result.append("\u{000C}")
                    case "r": result.append("\r")
                    case "\"": result.append("\"")
                    case "\\": result.append("\\")
                    case "u", "U":
                        let count = escaped == "u" ? 4 : 8
                        guard position + count <= source.count else { throw failure }
                        let digits = String(String.UnicodeScalarView(source[position..<(position + count)]))
                        guard digits.unicodeScalars.allSatisfy({ (48...57).contains($0.value) || (65...70).contains($0.value) || (97...102).contains($0.value) }),
                              let value = UInt32(digits, radix: 16), let scalar = Unicode.Scalar(value) else { throw failure }
                        result.append(scalar); position += count
                    default: throw failure
                    }
                } else { result.append(c) }
            }
            throw failure
        }
    }
}
