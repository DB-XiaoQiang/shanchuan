import XCTest
@testable import CopyToolCore

final class TransferLogTests: XCTestCase {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testReloadPreservesMetadataLevelsAndCallerOrder() throws {
        let root = try makeRoot()
        let entries = TransferLogEntry.Level.allCases.enumerated().map { index, level in
            TransferLogEntry(date: Date(timeIntervalSince1970: Double(index)), level: level, message: "中文日志\n\(index)")
        }
        try TransferLogRepository(root: root).save(entries)

        let reloaded = try TransferLogRepository(root: root).load()
        XCTAssertEqual(reloaded, entries)
        XCTAssertEqual(reloaded.map(\.level), TransferLogEntry.Level.allCases)
    }

    func testSaveKeepsFirstEntriesUpToLimit() throws {
        let repository = TransferLogRepository(root: try makeRoot(), limit: 2)
        let entries = (0..<4).map { TransferLogEntry(message: "日志 \($0)") }
        try repository.save(entries)

        XCTAssertEqual(try repository.load(), Array(entries.prefix(2)))
        let stored = try JSONDecoder().decode([TransferLogEntry].self, from: Data(contentsOf: repository.file))
        XCTAssertEqual(stored, Array(entries.prefix(2)))
    }

    func testLoadTruncatesInMemoryWithoutRewritingOriginalFile() throws {
        let repository = TransferLogRepository(root: try makeRoot(), limit: 2)
        let entries = (0..<4).map { TransferLogEntry(message: "日志 \($0)") }
        let original = try JSONEncoder().encode(entries)
        try original.write(to: repository.file)

        XCTAssertEqual(try repository.load(), Array(entries.prefix(2)))
        XCTAssertEqual(try Data(contentsOf: repository.file), original)
    }

    func testMissingAndEmptyLogsLoadAsEmpty() throws {
        let repository = TransferLogRepository(root: try makeRoot())
        XCTAssertEqual(try repository.load(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.file.path))

        try repository.save([])
        XCTAssertEqual(try TransferLogRepository(root: repository.root).load(), [])
    }

    func testCorruptLogThrowsAndKeepsOriginalBytes() throws {
        let repository = TransferLogRepository(root: try makeRoot())
        for original in [Data("broken JSON".utf8), Data("{}".utf8), Data("[{\"message\":\"missing metadata\"}]".utf8)] {
            try original.write(to: repository.file)
            XCTAssertThrowsError(try repository.load())
            XCTAssertEqual(try Data(contentsOf: repository.file), original)
        }
    }

    func testFirstSaveAndReplacementUsePrivatePermissions() throws {
        let repository = TransferLogRepository(root: try makeRoot())
        let entry = TransferLogEntry(message: "不包含凭据的合成日志")
        try repository.save([entry])
        XCTAssertEqual(try permissions(repository.file), 0o600)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: repository.file.path)
        try repository.save([entry, entry])
        XCTAssertEqual(try permissions(repository.file), 0o600)
        XCTAssertEqual(try repository.load(), [entry, entry])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: repository.root.path), ["transfer-logs.json"])
    }

    func testZeroAndNegativeLimitsRetainNoEntries() throws {
        for limit in [0, -1] {
            let repository = TransferLogRepository(root: try makeRoot(), limit: limit)
            try repository.save([TransferLogEntry(message: "合成日志")])
            XCTAssertEqual(try repository.load(), [])
            XCTAssertEqual(repository.limit, 0)
        }
    }

    func testDefaultLimitRetainsOneThousandEntries() throws {
        let repository = TransferLogRepository(root: try makeRoot())
        let entries = (0..<1001).map { TransferLogEntry(message: "合成日志 \($0)") }
        try repository.save(entries)
        XCTAssertEqual(try repository.load(), Array(entries.prefix(1000)))
    }

    func testFailedReplacementCleansTemporaryFileAndKeepsExistingDirectory() throws {
        let repository = TransferLogRepository(root: try makeRoot())
        try FileManager.default.createDirectory(at: repository.file, withIntermediateDirectories: false)
        XCTAssertThrowsError(try repository.save([TransferLogEntry(message: "合成日志")]))

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: repository.file.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: repository.root.path), ["transfer-logs.json"])
    }

    private func permissions(_ file: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}
