import XCTest
@testable import CopyToolCore

final class PreparationCancellationTests: XCTestCase {
    func testTextPreparationRejectsCancellationAndResetsForNextTransfer() throws {
        let transfer = FTPTransfer()
        let entry = HistoryEntry(kind: .text, content: "合成文本\r\n")
        let preferences = AppPreferences()
        transfer.cancel()
        XCTAssertThrowsError(try TransferProtocol.prepare(entry: entry, preferences: preferences, timestamp: 1, transfer: transfer)) { error in
            guard case FTPTransferError.cancelled = error else {
                return XCTFail("Expected cancellation, received \(error)")
            }
        }

        transfer.resetCancellation()
        let plan = try TransferProtocol.prepare(entry: entry, preferences: preferences, timestamp: 2, transfer: transfer)
        defer { plan.temporaryFiles.forEach { try? FileManager.default.removeItem(at: $0) } }
        XCTAssertEqual(plan.files.count, 1)
        XCTAssertEqual(plan.files[0].remoteName, "copy.temp.2")
        XCTAssertEqual(try Data(contentsOf: plan.files[0].file), Data(entry.content.utf8))
    }

    func testFolderPreparationRejectsCancellationAndResetsForZipAndHash() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("synthetic zip cancellation fixture".utf8).write(to: root.appendingPathComponent("source.txt"))
        let entry = HistoryEntry(kind: .file, content: "", paths: [root.path])
        let transfer = FTPTransfer()
        transfer.cancel()
        XCTAssertThrowsError(try TransferProtocol.prepare(entry: entry, preferences: AppPreferences(), timestamp: 3, transfer: transfer)) { error in
            guard case FTPTransferError.cancelled = error else {
                return XCTFail("Expected cancellation, received \(error)")
            }
        }

        transfer.resetCancellation()
        let plan = try TransferProtocol.prepare(entry: entry, preferences: AppPreferences(), timestamp: 4, transfer: transfer)
        defer { plan.temporaryFiles.forEach { try? FileManager.default.removeItem(at: $0) } }
        XCTAssertEqual(plan.files.count, 2)
        XCTAssertEqual(try Data(contentsOf: plan.files[0].file).prefix(2), Data("PK".utf8))
        let manifest = try String(contentsOf: plan.files[1].file, encoding: .utf8)
        XCTAssertTrue(manifest.hasPrefix("file=folder:" + root.lastPathComponent + "|"))
        XCTAssertTrue(manifest.hasSuffix("\r\n4"))
        XCTAssertEqual(manifest.components(separatedBy: "|")[1].components(separatedBy: "\r\n")[0].count, 32)
    }
}
