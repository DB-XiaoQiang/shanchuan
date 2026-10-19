import XCTest
import CopyToolCore
@testable import CopyToolApp

final class TransferLogIntegrationTests: XCTestCase {
    @MainActor
    func testExplicitLogSurvivesModelRecreation() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writePreferences(to: root)

        let model = makeModel(root: root)
        model.log("合成日志：准备发送")
        model.log("合成日志：发送完成", level: .success)
        let expected = model.transferLogs
        XCTAssertEqual(expected.map(\.level), [.success, .info])
        XCTAssertEqual(model.logs.count, 2)
        XCTAssertTrue(model.logPersistenceError.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: model.transferLogFile.path))

        let reopened = makeModel(root: root)
        XCTAssertEqual(reopened.transferLogs, expected)
        XCTAssertEqual(reopened.logs, model.logs)
        XCTAssertTrue(reopened.logPersistenceError.isEmpty)
    }

    @MainActor
    func testLegacyMigrationRestoresDeliveryStatesWithoutClipboardContentOrFullPaths() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writePreferences(to: root)
        let statuses = ["已发送", "发送失败", "已取消", "等待发送", "发送中"]
        let levels: [TransferLogEntry.Level] = [.success, .error, .cancelled, .warning, .warning]
        let now = Date()
        var legacy: [HistoryEntry] = statuses.enumerated().map { index, status in
            var entry = HistoryEntry(kind: .text, content: "禁止写入日志的合成正文-\(index)",
                                     date: now.addingTimeInterval(-Double(index) * 60))
            entry.status = status
            return entry
        }
        var file = HistoryEntry(kind: .file, content: "禁止写入日志的文件内容摘要",
                                paths: [root.appendingPathComponent("私有父目录/合成归档.zip").path],
                                date: now.addingTimeInterval(-360))
        file.status = "已发送"
        legacy.append(file)
        let local = HistoryEntry(kind: .text, content: "仅本地正文不应回填",
                                 date: now.addingTimeInterval(-420))
        legacy.append(local)
        try HistoryRepository(root: root).save(legacy)

        let model = makeModel(root: root)
        XCTAssertEqual(model.transferLogs.count, 6)
        XCTAssertFalse(model.transferLogs.contains { $0.id == local.id })
        for (index, entry) in legacy.prefix(5).enumerated() {
            let restored = try XCTUnwrap(model.transferLogs.first { $0.id == entry.id })
            XCTAssertEqual(restored.date, entry.date)
            XCTAssertEqual(restored.level, levels[index])
            XCTAssertTrue(restored.message.contains("历史记录恢复"))
            XCTAssertTrue(restored.message.contains("记录创建时间"))
            if ["等待发送", "发送中"].contains(entry.status) {
                XCTAssertTrue(restored.message.contains("最终结果未知"))
            }
        }
        let restoredFile = try XCTUnwrap(model.transferLogs.first { $0.id == file.id })
        XCTAssertTrue(restoredFile.message.contains("合成归档.zip"))
        let allMessages = model.transferLogs.map(\.message).joined(separator: "\n")
        for entry in legacy { XCTAssertFalse(allMessages.contains(entry.content)) }
        XCTAssertFalse(allMessages.contains("私有父目录"))
        XCTAssertFalse(allMessages.contains(root.path))
        XCTAssertEqual(try model.repository.load(), legacy)
    }

    @MainActor
    func testLegacyMigrationRunsOnceAndLogsRemainAfterHistoryIsRemoved() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writePreferences(to: root)
        let history = try HistoryRepository(root: root)
        var entry = HistoryEntry(kind: .text, content: "合成历史正文")
        entry.status = "已发送"
        try history.save([entry])

        let first = makeModel(root: root)
        XCTAssertEqual(first.transferLogs.count, 1)
        let recovered = first.transferLogs
        let second = makeModel(root: root)
        XCTAssertEqual(second.transferLogs, recovered)
        XCTAssertEqual(second.transferLogs.count, 1)

        try FileManager.default.removeItem(at: root.appendingPathComponent("history.json"))
        let withoutHistory = makeModel(root: root)
        XCTAssertTrue(withoutHistory.entries.isEmpty)
        XCTAssertEqual(withoutHistory.transferLogs, recovered)
        XCTAssertTrue(withoutHistory.logPersistenceError.isEmpty)
    }

    @MainActor
    func testCorruptLogFileIsPreservedAndNewLogsRemainVisibleInMemory() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writePreferences(to: root)
        let file = TransferLogRepository(root: root).file
        let originalBytes = Data("{broken synthetic log\u{0000}".utf8)
        try originalBytes.write(to: file)

        let model = makeModel(root: root)
        XCTAssertTrue(model.logPersistenceError.contains("读取日志失败"))
        XCTAssertTrue(model.transferLogs.isEmpty)
        model.log("损坏日志后的合成新事件", level: .warning)

        XCTAssertEqual(model.transferLogs.count, 1)
        XCTAssertEqual(model.transferLogs.first?.message, "损坏日志后的合成新事件")
        XCTAssertTrue(model.logs.first?.contains("损坏日志后的合成新事件") == true)
        XCTAssertTrue(model.logPersistenceError.contains("原文件已保留"))
        XCTAssertEqual(try Data(contentsOf: file), originalBytes)
        let reopened = makeModel(root: root)
        XCTAssertTrue(reopened.logPersistenceError.contains("读取日志失败"))
        XCTAssertEqual(try Data(contentsOf: file), originalBytes)
    }

    @MainActor
    func testLogSanitizesCurrentAndPersistedPasswordsControlCharactersAndLength() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writePreferences(to: root, configured: true)
        let persistedSecret = "synthetic-persisted-secret"
        let currentSecret = "synthetic-edited-secret"
        let model = makeModel(root: root, secret: persistedSecret)
        XCTAssertEqual(model.password, persistedSecret)
        model.password = currentSecret
        model.log("合成 \(persistedSecret)\n\t\(currentSecret)\u{0000}\r" + String(repeating: "长", count: 3000))

        let message = try XCTUnwrap(model.transferLogs.first?.message)
        XCTAssertEqual(message.count, 2048)
        XCTAssertFalse(message.contains(persistedSecret))
        XCTAssertFalse(message.contains(currentSecret))
        XCTAssertTrue(message.contains("[已隐藏]"))
        XCTAssertFalse(message.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })
        XCTAssertEqual(model.message, message)
        let stored = try Data(contentsOf: model.transferLogFile)
        let storedText = try XCTUnwrap(String(data: stored, encoding: .utf8))
        XCTAssertFalse(storedText.contains(persistedSecret))
        XCTAssertFalse(storedText.contains(currentSecret))
        XCTAssertEqual(makeModel(root: root, secret: persistedSecret).transferLogs, model.transferLogs)
    }

    @MainActor
    func testMissingSyntheticSourceLogsQueueStartAndPreparationFailureWithoutNetwork() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writePreferences(to: root, configured: true)
        let model = makeModel(root: root)
        XCTAssertNil(model.preferences.validationError)
        let missingFile = root.appendingPathComponent("missing-synthetic-source.zip")
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingFile.path))

        // prepare() 读取本地源文件元数据即失败；不会进入 curl 上传或解析 .invalid 主机。
        model.addFiles([missingFile], automatic: false)
        try await waitUntil { model.transferSnapshot.phase == .failed && model.activeTransfer.isEmpty }

        let messages = model.transferLogs.map(\.message)
        XCTAssertTrue(messages.contains { $0.hasPrefix("已加入发送队列：") })
        XCTAssertTrue(messages.contains { $0.hasPrefix("开始发送：") })
        XCTAssertTrue(messages.contains { $0.hasPrefix("发送失败：") })
        XCTAssertFalse(messages.contains { $0.hasPrefix("准备完成：") || $0.hasPrefix("开始上传：") })
        XCTAssertEqual(model.transferLogs.first?.level, .error)
        XCTAssertEqual(model.entries.first?.status, "发送失败")
        XCTAssertEqual(model.queued, 0)
        XCTAssertTrue(model.logPersistenceError.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingFile.path))
        let reopened = makeModel(root: root)
        XCTAssertEqual(reopened.transferLogs, model.transferLogs)
        XCTAssertEqual(reopened.entries.first?.status, "发送失败")
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TransferLogIntegrationTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writePreferences(to root: URL, configured: Bool = false) throws {
        var preferences = AppPreferences()
        preferences.shortcuts.enabled = false
        preferences.notificationsEnabled = false
        if configured {
            preferences.host = "synthetic.invalid"
            preferences.username = "synthetic-user"
            preferences.directory = "/synthetic-destination"
        }
        try JSONEncoder().encode(preferences).write(to: root.appendingPathComponent("preferences.json"))
    }

    @MainActor
    private func makeModel(root: URL, secret: String = "synthetic-fake-vault-secret") -> AppModel {
        // 注入合成密码库，测试不调用系统钥匙串、剪贴板或前台应用。
        AppModel(root: root, readPassword: { secret }, writePassword: { _ in })
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            // 让出 MainActor，允许 worker 的结束回调执行；不能用阻塞等待。
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("合成本地准备失败没有在三秒内结束")
    }
}
