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
    public init(files: [PreparedUpload], temporaryFiles: [URL]) {
        self.files = files; self.temporaryFiles = temporaryFiles
    }
}

public enum TransferProtocolError: Error, LocalizedError {
    case invalidName(String), duplicateEntity(String), emptyFiles, invalidDirectory
    public var errorDescription: String? {
        switch self {
        case .invalidName(let name): return "协议不能安全表示文件名：\(name)"
        case .duplicateEntity(let name): return "多个文件映射为同一远端实体：\(name)"
        case .emptyFiles: return "没有可发送的文件。"
        case .invalidDirectory: return "远端目录无效。"
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
        var specs: [(url: URL, name: String, directory: String, folder: Bool, marked: Bool)] = []
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
                guard entities.insert(key).inserted, key != systemDir + "/" + controlName else { throw TransferProtocolError.duplicateEntity(remote) }
                specs.append((url, name, directory, folder, marked))
            }
        }
        let root = fm.temporaryDirectory.appendingPathComponent("copytool-protocol-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let control = root.appendingPathComponent("control")
            var uploads: [PreparedUpload] = []
            var manifest: [String] = []
            for (index, spec) in specs.enumerated() {
                try transfer.checkCancellation()
                let payload: URL
                let remote: String
                if spec.folder {
                    payload = root.appendingPathComponent("archive-\(index)")
                    try transfer.zip(directory: spec.url, destination: payload)
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
            return PreparedTransfer(files: uploads, temporaryFiles: [root])
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
