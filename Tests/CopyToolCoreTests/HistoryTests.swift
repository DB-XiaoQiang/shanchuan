import XCTest
@testable import CopyToolCore

final class HistoryTests: XCTestCase {
    func testRoundTripAndPrune() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try HistoryRepository(root: root)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let recent = HistoryEntry(kind: .text, content: "中文\nhello", date: now)
        let old = HistoryEntry(kind: .file, content: "file", paths: ["/tmp/a"], date: now.addingTimeInterval(-91 * 86400))
        try repository.save([recent, old])
        XCTAssertEqual(try repository.load(), [recent, old])
        XCTAssertEqual(repository.prune([recent, old], days: 90, now: now), [recent])
    }
    func testMediaCleanupNeverDeletesSourceFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try HistoryRepository(root: root)
        let image = try repository.saveImage(Data([1, 2, 3]))
        let external = root.appendingPathComponent("source.txt")
        try Data("keep".utf8).write(to: external)
        try repository.removeUnreferencedMedia(entries: [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: image.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: external.path))
    }
    func testFilterAndValidation() {
        let entry = HistoryEntry(kind: .text, content: "Hello 中文")
        XCTAssertTrue(entry.matches(query: "HELLO", kind: .text))
        XCTAssertFalse(entry.matches(query: "", kind: .file))
        var config = AppPreferences()
        XCTAssertNotNil(config.validationError)
        config.host = "127.0.0.1"; config.username = "test"
        XCTAssertNil(config.validationError)
        config.port = 0; XCTAssertNotNil(config.validationError)
    }
}
