import XCTest
@testable import CopyToolCore

final class ProtocolTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func source(_ name: String, _ bytes: String) throws -> URL {
        let file = root.appendingPathComponent(name)
        try Data(bytes.utf8).write(to: file)
        return file
    }
    private func cleanup(_ plan: PreparedTransfer) { for file in plan.temporaryFiles { try? FileManager.default.removeItem(at: file) } }
    private var prefs: AppPreferences { var p = AppPreferences(); p.directory = "/share/"; return p }

    func testTextIsExactUTF8WithTimestampedControl() throws {
        let text = "你好\r\nfile=literal|text, preserved\n"
        let plan = try TransferProtocol.prepare(entry: HistoryEntry(kind: .text, content: text), preferences: prefs, timestamp: 123456)
        defer { cleanup(plan) }
        XCTAssertEqual(plan.files.count, 1)
        XCTAssertEqual(plan.files[0].remoteName, "copy.temp.123456")
        XCTAssertEqual(plan.files[0].directory, "/share/system_temp")
        XCTAssertEqual(try Data(contentsOf: plan.files[0].file), Data(text.utf8))
        let mode = try FileManager.default.attributesOfItem(atPath: plan.temporaryFiles[0].path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o700)
    }

    func testFileManifestBytesAndOriginalNaming() throws {
        let a = try source("a.txt", "abc")
        let b = try source("document.docx", "abc")
        let entry = HistoryEntry(kind: .file, content: "", paths: [a.path, b.path])
        let plan = try TransferProtocol.prepare(entry: entry, preferences: prefs, timestamp: 42)
        defer { cleanup(plan) }
        XCTAssertEqual(plan.files.map(\.remoteName), ["a", "document.docx", "copy.temp.42"])
        XCTAssertEqual(try String(contentsOf: plan.files.last!.file, encoding: .utf8), "file=a.txt|900150983cd24fb0d6963f7d28e17f72,document.docx|900150983cd24fb0d6963f7d28e17f72\r\n42")
        try Data("changed after planning".utf8).write(to: a)
        XCTAssertEqual(try Data(contentsOf: plan.files[0].file), Data("abc".utf8))
    }

    func testOfficeMarkerRequiresBytesAndFlag() throws {
        let file = try source("marked.docx", "877D1Cpayload")
        let entry = HistoryEntry(kind: .file, content: "", paths: [file.path])
        var p = prefs; p.directory = "/group/share///"; p.decryptPrefix = "/decrypt///"
        let marked = try TransferProtocol.prepare(entry: entry, preferences: p, timestamp: 2)
        defer { cleanup(marked) }
        XCTAssertEqual(marked.files[0].directory, "/decrypt/share")
        XCTAssertTrue(try String(contentsOf: marked.files.last!.file).hasPrefix("file=877D1C:marked.docx|"))
        p.autoDecrypt = false
        let plain = try TransferProtocol.prepare(entry: entry, preferences: p, timestamp: 3)
        defer { cleanup(plain) }
        XCTAssertEqual(plain.files[0].directory, "/group/share/system_temp")
        XCTAssertTrue(try String(contentsOf: plain.files.last!.file).hasPrefix("file=marked.docx|"))
    }

    func testFolderIsZipWithFolderManifestAndNoZipSuffix() throws {
        let folder = root.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("sample".utf8).write(to: folder.appendingPathComponent("hello.txt"))
        let plan = try TransferProtocol.prepare(entry: HistoryEntry(kind: .file, content: "", paths: [folder.path]), preferences: prefs, timestamp: 5)
        defer { cleanup(plan) }
        XCTAssertEqual(plan.files.first!.remoteName, "docs")
        XCTAssertEqual(try Data(contentsOf: plan.files.first!.file).prefix(2), Data("PK".utf8))
        let listing = Process(), output = Pipe()
        listing.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        listing.arguments = ["-Z1", plan.files.first!.file.path]
        listing.standardOutput = output
        try listing.run()
        let names = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        listing.waitUntilExit()
        XCTAssertEqual(listing.terminationStatus, 0)
        XCTAssertTrue(names.split(separator: "\n").contains("hello.txt"))
        XCTAssertFalse(names.contains("docs/hello.txt"))
        let manifest = try String(contentsOf: plan.files.last!.file)
        XCTAssertTrue(manifest.hasPrefix("file=folder:docs|"))
        XCTAssertTrue(manifest.hasSuffix("\r\n5"))
        XCTAssertEqual(manifest.components(separatedBy: "|")[1].components(separatedBy: "\r\n")[0].count, 32)
    }

    func testRejectsAmbiguousManifestAndEntityCollisions() throws {
        for name in ["bad,name.txt", "bad|name.txt", "bad\nname.txt", "folder:literal"] {
            let file = try source(name, "abc")
            XCTAssertThrowsError(try TransferProtocol.prepare(entry: HistoryEntry(kind: .file, content: "", paths: [file.path]), preferences: prefs, timestamp: 7))
        }
        let a = try source("same.txt", "a"), b = try source("same.bin", "b")
        XCTAssertThrowsError(try TransferProtocol.prepare(entry: HistoryEntry(kind: .file, content: "", paths: [a.path, b.path]), preferences: prefs, timestamp: 7))
    }
}
