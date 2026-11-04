import XCTest
import CryptoKit
import Darwin
@testable import CopyToolCore

final class DirectoryExclusionTests: XCTestCase {
    func testNamesDirectoriesAndWildcardsAtAnyDepth() throws {
        let rules = try DirectoryExclusions(".git/\nnode_modules/\n*.log\n缓存?.txt")
        XCTAssertTrue(rules.excludes(relativePath: "src/.git", isDirectory: true))
        XCTAssertTrue(rules.excludes(relativePath: "node_modules", isDirectory: true))
        XCTAssertFalse(rules.excludes(relativePath: "node_modules", isDirectory: false))
        XCTAssertTrue(rules.excludes(relativePath: "src/debug.log", isDirectory: false))
        XCTAssertFalse(rules.excludes(relativePath: "src/debug.LOG", isDirectory: false))
        XCTAssertTrue(rules.excludes(relativePath: "中文/缓存😀.txt", isDirectory: false))
        XCTAssertFalse(rules.excludes(relativePath: "缓存两个.txt", isDirectory: false))
        XCTAssertFalse(rules.excludes(relativePath: "src/important.txt", isDirectory: false))
    }

    func testAnchoredPathsAndRecursiveStarIncludingZeroDirectories() throws {
        let rules = try DirectoryExclusions("/build/\nsrc/**/*.log\n**/cache/")
        XCTAssertTrue(rules.excludes(relativePath: "build", isDirectory: true))
        XCTAssertFalse(rules.excludes(relativePath: "src/build", isDirectory: true))
        XCTAssertTrue(rules.excludes(relativePath: "src/debug.log", isDirectory: false))
        XCTAssertTrue(rules.excludes(relativePath: "src/a/b/debug.log", isDirectory: false))
        XCTAssertFalse(rules.excludes(relativePath: "other/src/debug.log", isDirectory: false))
        XCTAssertTrue(rules.excludes(relativePath: "cache", isDirectory: true))
        XCTAssertTrue(rules.excludes(relativePath: "a/b/cache", isDirectory: true))
        XCTAssertFalse(rules.excludes(relativePath: "a/cache", isDirectory: false))
        let singleLevel = try DirectoryExclusions("src/*.log")
        XCTAssertFalse(singleLevel.excludes(relativePath: "src/a/debug.log", isDirectory: false))
    }

    func testCommentsCRLFAndInvalidRules() throws {
        XCTAssertTrue(try DirectoryExclusions(" \n# comment\n\t").isEmpty)
        XCTAssertTrue(try DirectoryExclusions("  # comment\r\n*.log\r\n").excludes(relativePath: "a.log", isDirectory: false))
        for rule in ["!keep", "../outside", "/", "./file", "a//b", "bad\tname", "bad\u{0}name", "a\\b", String(repeating: "x", count: 513)] {
            XCTAssertThrowsError(try DirectoryExclusions(rule), rule)
        }
        XCTAssertThrowsError(try DirectoryExclusions((1...201).map { "file\($0)" }.joined(separator: "\n")))
    }

    func testPreferencesDecodeLegacyAndRoundTripNewRules() throws {
        XCTAssertEqual(try JSONDecoder().decode(AppPreferences.self, from: Data("{}".utf8)).directoryExclusionRules, "")
        var preferences = AppPreferences()
        preferences.host = "synthetic.invalid"; preferences.username = "fixture"
        preferences.directoryExclusionRules = ".git/\nnode_modules/\n*.log"
        XCTAssertNil(preferences.validationError)
        XCTAssertEqual(try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(preferences)), preferences)
        preferences.directoryExclusionRules = "../private"
        XCTAssertTrue(preferences.validationError?.contains("目录排除规则") == true)
    }

    func testPreparedArchiveFiltersContentsAndPreservesManifestUnicodeLinksAndSource() throws {
        try withFixture { root, source in
            let files = [".git/config", "src/node_modules/pkg/index.js", "debug.log", "src/nested/trace.log",
                         ".DS_Store", "src/.DS_Store", "build/main.bin", "src/build/keep.txt", "src/中文😀.txt", "keep.bin"]
            for path in files { try write(path, in: source, text: "fixture:" + path) }
            try FileManager.default.createDirectory(at: source.appendingPathComponent("empty"), withIntermediateDirectories: false)
            let outside = root.appendingPathComponent("outside.txt")
            try Data("DO_NOT_ARCHIVE_TARGET_BYTES".utf8).write(to: outside)
            try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("link").path, withDestinationPath: outside.path)
            var preferences = AppPreferences()
            preferences.directoryExclusionRules = ".git/\nnode_modules/\n*.log\n.DS_Store\n/build/"
            let plan = try TransferProtocol.prepare(entry: HistoryEntry(kind: .file, content: "", paths: [source.path]),
                preferences: preferences, timestamp: 123)
            defer { plan.temporaryFiles.forEach { try? FileManager.default.removeItem(at: $0) } }
            XCTAssertEqual(plan.excludedItemCount, 7)
            XCTAssertEqual(plan.files.map(\.remoteName), ["source", "copy.temp.123"])
            let digest = Insecure.MD5.hash(data: try Data(contentsOf: plan.files[0].file)).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(try String(contentsOf: plan.files[1].file), "file=folder:source|" + digest + "\r\n123")
            try inspectZIP(plan.files[0].file, script: #"""
import sys, zipfile, stat
with zipfile.ZipFile(sys.argv[1]) as z:
    names = set(z.namelist())
    files = {p for p in names if not p.endswith('/')}
    assert files == {'src/build/keep.txt', 'src/中文😀.txt', 'keep.bin', 'link'}, files
    assert 'empty/' in names, names
    assert z.read('src/中文😀.txt').decode() == 'fixture:src/中文😀.txt'
    link = z.getinfo('link')
    assert stat.S_ISLNK(link.external_attr >> 16)
    assert z.read('link').decode().endswith('/outside.txt')
    assert all(z.read(p) != b'DO_NOT_ARCHIVE_TARGET_BYTES' for p in files)
    assert all(i.flag_bits & 0x800 for i in z.infolist())
    assert z.testzip() is None
"""#)
            for path in files { XCTAssertEqual(try String(contentsOf: source.appendingPathComponent(path)), "fixture:" + path) }
            XCTAssertEqual(try String(contentsOf: outside), "DO_NOT_ARCHIVE_TARGET_BYTES")
        }
    }

    func testEmptyRulesKeepAllFilesAndDirectFileIgnoresDirectoryRules() throws {
        try withFixture { root, source in
            try write(".git/config", in: source, text: "keep")
            let archive = root.appendingPathComponent("all.zip")
            XCTAssertEqual(try FTPTransfer().zip(directory: source, destination: archive), 0)
            try inspectZIP(archive, script: "import sys,zipfile; assert zipfile.ZipFile(sys.argv[1]).read('.git/config') == b'keep'")
            let file = source.appendingPathComponent("direct.log")
            try Data("explicit file".utf8).write(to: file)
            var preferences = AppPreferences(); preferences.directoryExclusionRules = "*"
            let plan = try TransferProtocol.prepare(entry: HistoryEntry(kind: .file, content: "", paths: [file.path]), preferences: preferences, timestamp: 2)
            defer { plan.temporaryFiles.forEach { try? FileManager.default.removeItem(at: $0) } }
            XCTAssertEqual(plan.excludedItemCount, 0)
            XCTAssertEqual(try String(contentsOf: plan.files[0].file), "explicit file")
        }
    }

    func testAllExcludedStillProducesValidEmptyZIP() throws {
        try withFixture { root, source in
            try write("ignored/child", in: source, text: "skip")
            let archive = root.appendingPathComponent("empty.zip")
            XCTAssertEqual(try FTPTransfer().zip(directory: source, destination: archive, exclusionRules: "*"), 1)
            try inspectZIP(archive, script: "import sys,zipfile; z=zipfile.ZipFile(sys.argv[1]); assert z.namelist() == []; assert z.testzip() is None")
        }
    }

    func testSelectedRootIsAlwaysRetainedAndInsideDestinationIsRejected() throws {
        try withFixture { root, source in
            try write("keep.txt", in: source, text: "keep")
            let archive = root.appendingPathComponent("selected.zip")
            XCTAssertEqual(try FTPTransfer().zip(directory: source, destination: archive, exclusionRules: "source/"), 0)
            try inspectZIP(archive, script: "import sys,zipfile; assert zipfile.ZipFile(sys.argv[1]).read('keep.txt') == b'keep'")
            XCTAssertThrowsError(try FTPTransfer().zip(directory: source, destination: source.appendingPathComponent("bad.zip"), exclusionRules: "*.log"))
        }
    }

    func testExcludedSpecialFileIsNeverOpenedAndFailureCleansSnapshot() throws {
        try withFixture { root, source in
            let fifo = source.appendingPathComponent("skip.pipe")
            XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
            let destination = root.appendingPathComponent("result.zip")
            let before = try snapshots()
            XCTAssertEqual(try FTPTransfer().zip(directory: source, destination: destination, exclusionRules: "*.pipe"), 1)
            XCTAssertEqual(try snapshots(), before)
            let failed = root.appendingPathComponent("failed.zip")
            XCTAssertThrowsError(try FTPTransfer().zip(directory: source, destination: failed, exclusionRules: "*.log"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: failed.path))
            XCTAssertEqual(try snapshots(), before)
        }
    }

    func testSnapshotCopyChecksCancellationWithinLargeFile() throws {
        try withFixture { root, source in
            try Data(repeating: 7, count: 8 * 1_048_576).write(to: source.appendingPathComponent("large.bin"))
            var checks = 0
            XCTAssertThrowsError(try FilteredDirectorySnapshot.copy(source: source, destination: root.appendingPathComponent("snapshot"),
                rules: DirectoryExclusions("*.log"), checkCancellation: {
                    checks += 1
                    if checks == 5 { throw FTPTransferError.cancelled }
                })) { error in
                guard case FTPTransferError.cancelled = error else { return XCTFail("Expected cancellation") }
            }
            XCTAssertEqual(checks, 5)
            XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("large.bin")).count, 8 * 1_048_576)
        }
    }

    private func snapshots() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path).filter { $0.hasPrefix("copytool-filter-") })
    }
    private func withFixture(_ action: (URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try action(root, source)
    }
    private func write(_ path: String, in directory: URL, text: String) throws {
        let file = directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }
    private func inspectZIP(_ archive: URL, script: String) throws {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", script, archive.path]
        process.standardOutput = output; process.standardError = output
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: bytes, as: UTF8.self))
    }
}
