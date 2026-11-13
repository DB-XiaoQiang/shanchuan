import Foundation
import CryptoKit

public struct PreparedUpload: Sendable {
    public let file: URL
    public let remoteName: String
    public let directory: String
    public init(file: URL, remoteName: String, directory: String) {
        self.file = file; self.remoteName = remoteName; self.directory = directory
    }
}

public struct PreparedTransfer: Sendable {
    public let files: [PreparedUpload]
    /// Includes a private temporary directory; remove these URLs after success or failure.
    public let temporaryFiles: [URL]
    public let excludedItemCount: Int
    public let groupedFileFolders: [String]
    public init(files: [PreparedUpload], temporaryFiles: [URL], excludedItemCount: Int = 0, groupedFileFolders: [String] = []) {
        self.files = files; self.temporaryFiles = temporaryFiles; self.excludedItemCount = excludedItemCount
        self.groupedFileFolders = groupedFileFolders
    }
}

public enum TransferProtocolError: Error, LocalizedError {
    case invalidName(String), duplicateEntity(String), emptyFiles, invalidDirectory
    public var errorDescription: String? {
        switch self {
        case .invalidName(let name): return L10n.format("协议不能安全表示文件名：%@", String(describing: name))
        case .duplicateEntity(let name): return L10n.format("多个文件映射为同一远端实体：%@", String(describing: name))
        case .emptyFiles: return L10n.text("没有可发送的文件。")
        case .invalidDirectory: return L10n.text("远端目录无效。")
        }
    }
}

/// Builds the observed original wire format. The last upload is always the commit/control file.
public enum TransferProtocol {
    private static let office = Set(["doc", "docx", "xls", "xlsx", "ppt", "pptx"])

    public static func prepare(entry: HistoryEntry, preferences: AppPreferences, timestamp: Int64,
                               transfer: FTPTransfer = FTPTransfer()) throws -> PreparedTransfer {
        try transfer.checkCancellation()
        let fm = FileManager.default
        try validateName(preferences.textRemoteName)
        try validateDirectory(preferences.directory)
        let systemDir = trimSlash(preferences.directory) + "/system_temp"
        let controlName = preferences.textRemoteName + "." + String(timestamp)
        var specs: [(url: URL, name: String, directory: String, folder: Bool, marked: Bool, members: [URL])] = []
        var entities = Set<String>()
        if entry.kind != .text {
            guard !entry.paths.isEmpty else { throw TransferProtocolError.emptyFiles }
            for path in entry.paths {
                try transfer.checkCancellation()
                let url = URL(fileURLWithPath: path)
                let name = url.lastPathComponent
                try validateName(name)
                // These prefixes have protocol meaning and cannot represent literal names safely.
                guard !name.hasPrefix("folder:"), !name.hasPrefix("877D1C:") else { throw TransferProtocolError.invalidName(name) }
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true, values.isDirectory == true || values.isRegularFile == true else { throw FTPTransferError.invalidFile }
                let folder = values.isDirectory == true
                let isOffice = office.contains(url.pathExtension.lowercased())
                let marked = try !folder && isOffice && preferences.autoDecrypt && hasMarker(url)
                let remote = folder || isOffice ? name : url.deletingPathExtension().lastPathComponent
                try validateName(remote)
                let directory: String
                if marked {
                    try validateDirectory(preferences.decryptPrefix)
                    let tail = preferences.directory.split(separator: "/").last.map(String.init)
                    directory = trimSlash(preferences.decryptPrefix) + (tail.map { "/" + $0 } ?? "")
                } else { directory = systemDir }
                let key = directory + "/" + remote
                guard key != systemDir + "/" + controlName else { throw TransferProtocolError.duplicateEntity(remote) }
                entities.insert(key)
                specs.append((url, name, directory, folder, marked, []))
            }
        }
        // The receiver locates ordinary payloads by their stem. Preserve that wire
        // contract and use its existing folder protocol for colliding formats.
        let groups = Dictionary(grouping: specs.indices) { index in
            let spec = specs[index]
            let remote = spec.folder || office.contains(spec.url.pathExtension.lowercased())
                ? spec.name : spec.url.deletingPathExtension().lastPathComponent
            return spec.directory + "/" + remote
        }
        var handled = Set<Int>()
        var resolved = specs
        resolved.removeAll()
        for index in specs.indices {
            guard !handled.contains(index) else { continue }
            let spec = specs[index]
            let remote = spec.folder || office.contains(spec.url.pathExtension.lowercased())
                ? spec.name : spec.url.deletingPathExtension().lastPathComponent
            let indices = groups[spec.directory + "/" + remote]!
            handled.formUnion(indices)
            guard indices.count > 1 else { resolved.append(spec); continue }
            let members = indices.map { specs[$0] }
            // Identical full names cannot share a folder; marked Office files must
            // retain their decrypt route. Neither case is silently renamed.
            guard members.allSatisfy({ !$0.folder && !$0.marked && !office.contains($0.url.pathExtension.lowercased()) }),
                  Set(members.map(\.name)).count == members.count else {
                throw TransferProtocolError.duplicateEntity(remote)
            }
            var groupName: String
            repeat {
                groupName = "闪传多格式-\(timestamp)-\(UUID().uuidString.prefix(8))"
            } while !entities.insert(systemDir + "/" + groupName).inserted
            resolved.append((spec.url, groupName, systemDir, true, false, members.map(\.url)))
        }
        specs = resolved
        let root = fm.temporaryDirectory.appendingPathComponent("copytool-protocol-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let control = root.appendingPathComponent("control")
            var uploads: [PreparedUpload] = []
            var manifest: [String] = []
            var excludedItemCount = 0
            for (index, spec) in specs.enumerated() {
                try transfer.checkCancellation()
                let payload: URL
                let remote: String
                if spec.folder {
                    payload = root.appendingPathComponent("archive-\(index)")
                    if spec.members.isEmpty {
                        excludedItemCount += try transfer.zip(directory: spec.url, destination: payload, exclusionRules: preferences.directoryExclusionRules)
                    } else {
                        let group = root.appendingPathComponent("group-\(index)", isDirectory: true)
                        try fm.createDirectory(at: group, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                        for member in spec.members {
                            try transfer.checkCancellation()
                            try fm.copyItem(at: member, to: group.appendingPathComponent(member.lastPathComponent))
                        }
                        // These were explicitly selected files, so directory exclusions do not apply.
                        try transfer.zip(directory: group, destination: payload)
                    }
                    remote = spec.name
                } else {
                    payload = root.appendingPathComponent("payload-\(index)")
                    try fm.copyItem(at: spec.url, to: payload)
                    remote = office.contains(spec.url.pathExtension.lowercased()) ? spec.name : spec.url.deletingPathExtension().lastPathComponent
                }
                try transfer.checkCancellation()
                let hash = try md5(payload, transfer: transfer)
                let name = (spec.folder ? "folder:" : spec.marked ? "877D1C:" : "") + spec.name
                manifest.append(name + "|" + hash)
                uploads.append(PreparedUpload(file: payload, remoteName: remote, directory: spec.directory))
            }
            let content = entry.kind == .text ? entry.content : "file=" + manifest.joined(separator: ",") + "\r\n" + String(timestamp)
            try transfer.checkCancellation()
            try Data(content.utf8).write(to: control, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: control.path)
            uploads.append(PreparedUpload(file: control, remoteName: controlName, directory: systemDir))
            return PreparedTransfer(files: uploads, temporaryFiles: [root], excludedItemCount: excludedItemCount,
                                    groupedFileFolders: specs.filter { !$0.members.isEmpty }.map(\.name))
        } catch {
            try? fm.removeItem(at: root)
            throw error
        }
    }

    private static func validateName(_ value: String) throws {
        guard !value.isEmpty, value != ".", value != "..", !value.unicodeScalars.contains(where: { CharacterSet(charactersIn: ",|/\\\r\n\0").contains($0) }) else { throw TransferProtocolError.invalidName(value) }
    }
    private static func validateDirectory(_ value: String) throws {
        guard value.hasPrefix("/"), !value.split(separator: "/").contains(".."), !value.unicodeScalars.contains(where: { CharacterSet(charactersIn: "\r\n\0\\").contains($0) }) else { throw TransferProtocolError.invalidDirectory }
    }
    private static func trimSlash(_ value: String) -> String {
        var result = value
        while result.hasSuffix("/") { result.removeLast() }
        return result
    }
    private static func hasMarker(_ url: URL) throws -> Bool {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        return try file.read(upToCount: 6) == Data("877D1C".utf8)
    }
    private static func md5(_ url: URL, transfer: FTPTransfer) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = Insecure.MD5()
        while let data = try file.read(upToCount: 1_048_576), !data.isEmpty {
            try transfer.checkCancellation()
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
