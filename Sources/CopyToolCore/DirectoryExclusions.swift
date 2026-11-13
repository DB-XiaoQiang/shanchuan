import Foundation
import Darwin

/// Exclusion-only globs. Plain names match at any depth; paths are relative to the selected root.
public struct DirectoryExclusions: Sendable {
    private struct Rule: Sendable {
        let components: [String]
        let directoriesOnly: Bool
        let basenameOnly: Bool
    }
    private let rules: [Rule]
    public var isEmpty: Bool { rules.isEmpty }

    public init(_ text: String) throws {
        guard text.utf8.count <= 65_536 else {
            throw FTPTransferError.invalidSettings(L10n.text("目录排除规则过长，请控制在 64 KB 内。"))
        }
        var result: [Rule] = []
        for (index, raw) in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let reason: String?
            if line.utf8.count > 512 { reason = L10n.text("单条规则不能超过 512 字节") }
            else if line.hasPrefix("!") { reason = L10n.text("不支持 ! 反向规则，请只填写要排除的名称或路径") }
            else if line.contains("\\") || line.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
                reason = L10n.text("路径请使用 /，规则不能含控制字符或反斜杠")
            } else { reason = nil }
            if let reason { throw FTPTransferError.invalidSettings(L10n.format("目录排除规则第 %@ 行：%@。", String(describing: index + 1), String(describing: reason))) }
            let directoriesOnly = line.hasSuffix("/")
            let anchored = line.hasPrefix("/")
            var pattern = line
            if anchored { pattern.removeFirst() }
            if directoriesOnly && !pattern.isEmpty { pattern.removeLast() }
            let components = pattern.components(separatedBy: "/")
            guard !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
                throw FTPTransferError.invalidSettings(L10n.format("目录排除规则第 %@ 行：请填写有效的相对路径，不能包含 . 或 .. 路径段。", String(describing: index + 1)))
            }
            result.append(Rule(components: components, directoriesOnly: directoriesOnly,
                basenameOnly: !anchored && components.count == 1))
            guard result.count <= 200 else { throw FTPTransferError.invalidSettings(L10n.text("目录排除规则最多支持 200 条。")) }
        }
        rules = result
    }

    public func excludes(relativePath: String, isDirectory: Bool) -> Bool {
        let components = relativePath.components(separatedBy: "/")
        return rules.contains { rule in
            guard !rule.directoriesOnly || isDirectory else { return false }
            if rule.basenameOnly { return Self.componentMatches(rule.components[0], components.last ?? "") }
            var previous = [Bool](repeating: false, count: components.count + 1)
            previous[0] = true
            for pattern in rule.components {
                var next = [Bool](repeating: false, count: previous.count)
                if pattern == "**" {
                    next[0] = previous[0]
                    for index in components.indices { next[index + 1] = previous[index + 1] || next[index] }
                } else {
                    for index in components.indices {
                        next[index + 1] = previous[index] && Self.componentMatches(pattern, components[index])
                    }
                }
                previous = next
            }
            return previous[components.count]
        }
    }

    private static func componentMatches(_ pattern: String, _ name: String) -> Bool {
        let characters = Array(name)
        var previous = [Bool](repeating: false, count: characters.count + 1)
        previous[0] = true
        for character in pattern {
            var next = [Bool](repeating: false, count: previous.count)
            if character == "*" {
                next[0] = previous[0]
                for index in characters.indices { next[index + 1] = previous[index + 1] || next[index] }
            } else {
                for index in characters.indices {
                    next[index + 1] = previous[index] && (character == "?" || character == characters[index])
                }
            }
            previous = next
        }
        return previous[characters.count]
    }
}

/// Copies only retained entries. Excluded directories are pruned before enumerating their children.
/// Symbolic links are copied as links, never followed; the original source is never edited.
enum FilteredDirectorySnapshot {
    static func copy(source: URL, destination: URL, rules: DirectoryExclusions,
                     checkCancellation: () throws -> Void) throws -> Int {
        let fm = FileManager.default
        var excluded = 0
        func descend(_ directory: URL, _ target: URL, _ prefix: String) throws {
            try checkCancellation()
            try fm.createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            for child in try fm.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]) {
                try checkCancellation()
                let relative = prefix + child.lastPathComponent
                let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
                let isDirectory = values.isDirectory == true && values.isSymbolicLink != true
                if rules.excludes(relativePath: relative, isDirectory: isDirectory) { excluded += 1; continue }
                let output = target.appendingPathComponent(child.lastPathComponent)
                if values.isSymbolicLink == true {
                    try fm.createSymbolicLink(atPath: output.path, withDestinationPath: fm.destinationOfSymbolicLink(atPath: child.path))
                } else if isDirectory {
                    try descend(child, output, relative + "/")
                } else if values.isRegularFile == true {
                    try copyFile(child, output, checkCancellation: checkCancellation)
                } else {
                    throw FTPTransferError.failed(-1, L10n.text("目录中包含不支持的特殊文件，已停止打包。"))
                }
            }
        }
        try descend(source, destination, "")
        return excluded
    }

    private static func copyFile(_ source: URL, _ destination: URL, checkCancellation: () throws -> Void) throws {
        // Never follow a symlink if a file is replaced between enumeration and opening it.
        let descriptor = open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? input.close() }
        var status = stat()
        guard fstat(descriptor, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else { throw FTPTransferError.invalidFile }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw FTPTransferError.failed(-1, L10n.text("无法创建目录打包的临时副本。"))
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        while true {
            try checkCancellation()
            guard let bytes = try input.read(upToCount: 1_048_576), !bytes.isEmpty else { break }
            try output.write(contentsOf: bytes)
        }
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int(status.st_mode & 0o777)),
            .modificationDate: Date(timeIntervalSince1970: Double(status.st_mtimespec.tv_sec))], ofItemAtPath: destination.path)
    }
}
