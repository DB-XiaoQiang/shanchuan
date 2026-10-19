import Foundation

// Synthetic fixtures only. This executable never loads application preferences.
guard CommandLine.arguments.count == 2, let port = Int(CommandLine.arguments[1]), (1...65535).contains(port) else {
    fatalError("Usage: protocol-transfer-test <loopback-port>")
}

let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("copytool-protocol-integration-" + UUID().uuidString, isDirectory: true)
try fm.createDirectory(at: root, withIntermediateDirectories: false)
defer { try? fm.removeItem(at: root) }

var preferences = AppPreferences()
preferences.directory = "/share/"
preferences.textRemoteName = "copy.temp"
let settings = FTPSettings(host: "127.0.0.1", port: port, username: "fixture", password: "fixture-password", directory: "/share/")

@MainActor func send(_ entry: HistoryEntry, timestamp: Int64) throws {
    let plan = try TransferProtocol.prepare(entry: entry, preferences: preferences, timestamp: timestamp)
    defer { for url in plan.temporaryFiles { try? fm.removeItem(at: url) } }
    let worker = FTPTransfer()
    for upload in plan.files {
        var target = settings
        target.directory = upload.directory
        try worker.upload(file: upload.file, remoteName: upload.remoteName, settings: target, progress: { progress in
            precondition((0...1).contains(progress))
        })
    }
}

try send(HistoryEntry(kind: .text, content: "REA 独立版协议集成测试\r\n第二行 UTF-8：中文与 emoji 🧪\n"), timestamp: 1729000000001)
print("TEXT_PLAN_UPLOADED")

let file = root.appendingPathComponent("普通文件.txt")
try Data("独立文件内容\nline 2\r\n".utf8).write(to: file)
let folder = root.appendingPathComponent("测试文件夹", isDirectory: true)
let nested = folder.appendingPathComponent("子目录 with spaces", isDirectory: true)
try fm.createDirectory(at: nested, withIntermediateDirectories: true)
try Data("folder root\n".utf8).write(to: folder.appendingPathComponent("root.txt"))
try Data("相对路径内容\r\n".utf8).write(to: nested.appendingPathComponent("中文.txt"))
try Data([0, 1, 2, 127, 128, 254, 255]).write(to: nested.appendingPathComponent("bytes.bin"))
try send(HistoryEntry(kind: .file, content: "", paths: [file.path, folder.path]), timestamp: 1729000000002)
print("FILE_AND_FOLDER_PLAN_UPLOADED")
