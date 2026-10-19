import XCTest
import CopyToolCore
@testable import CopyToolApp

final class ClipboardDeliveryTests: XCTestCase {
    func testOrdinaryTextCopyIsIgnoredWithLegacySyncEnabled() async throws {
        try await MainActor.run {
            try withIsolatedModel { model in
                let item = HistoryEntry(kind: .text, content: "合成普通复制文本")
                model.add(item, automatic: true)
                try assertOrdinaryCopyIgnored(model)
            }
        }
    }

    func testOrdinaryFileCopyIsIgnoredWithLegacySyncEnabled() async throws {
        try await MainActor.run {
            try withIsolatedModel { model in
                // 不读取文件内容；只传入合成剪贴板的文件 URL 元数据。
                let file = model.root.appendingPathComponent("synthetic-file.txt")
                model.addFiles([file], automatic: true)
                try assertOrdinaryCopyIgnored(model)
            }
        }
    }

    func testOrdinaryFolderCopyIsIgnoredWithLegacySyncEnabled() async throws {
        try await MainActor.run {
            try withIsolatedModel { model in
                let folder = model.root.appendingPathComponent("合成文件夹", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                model.addFiles([folder], automatic: true)
                try assertOrdinaryCopyIgnored(model)
            }
        }
    }

    func testOrdinaryImageCopyIsIgnoredWithoutSavingMediaWithLegacySyncEnabled() async throws {
        try await MainActor.run {
            try withIsolatedModel { model in
                // 非图片的合成字节也应在解析或写盘前被忽略。
                model.addImage(Data([0x52, 0x45, 0x41]), automatic: true)
                try assertOrdinaryCopyIgnored(model)
                let media = try FileManager.default.contentsOfDirectory(
                    at: model.repository.mediaDirectory, includingPropertiesForKeys: nil)
                XCTAssertTrue(media.isEmpty)
            }
        }
    }

    func testExplicitDuplicateTextStillAttemptsDeliveryWithoutAddingHistory() async throws {
        try await MainActor.run {
            try withIsolatedModel { model in
                let original = HistoryEntry(kind: .text, content: "合成重复文本")
                model.entries = [original]
                try model.repository.save([original])
                let duplicate = HistoryEntry(kind: .text, content: original.content)
                XCTAssertNotEqual(original.id, duplicate.id)
                model.add(duplicate, automatic: false)
                try assertExplicitDeliveryReachedValidation(model)
                XCTAssertEqual(model.entries, [original])
                XCTAssertEqual(model.selected, original.id)
                XCTAssertEqual(try model.repository.load(), [original])
            }
        }
    }

    func testExplicitDuplicateFileAndFolderStillAttemptDelivery() async throws {
        try await MainActor.run {
            try withIsolatedModel { model in
                let urls = [
                    model.root.appendingPathComponent("synthetic-duplicate.txt"),
                    model.root.appendingPathComponent("合成重复文件夹", isDirectory: true)
                ]
                for url in urls {
                    let original = HistoryEntry(kind: .file, content: "1 个文件", paths: [url.path])
                    model.entries = [original]
                    try model.repository.save([original])
                    let count = model.entries.count
                    let logCount = model.logs.count
                    model.addFiles([url], automatic: false)
                    try assertExplicitDeliveryReachedValidation(model)
                    XCTAssertEqual(model.logs.count, logCount + 1)
                    XCTAssertEqual(model.entries.count, count)
                    XCTAssertEqual(model.selected, original.id)
                }
                XCTAssertEqual(try model.repository.load(), model.entries)
            }
        }
    }

    func testDisabledHistoryDoesNotBlockExplicitTextDelivery() async throws {
        try await MainActor.run {
            try withIsolatedModel(historyEnabled: false) { model in
                model.add(HistoryEntry(kind: .text, content: "合成无历史发送"), automatic: false)
                try assertExplicitDeliveryReachedValidation(model)
                XCTAssertTrue(model.entries.isEmpty)
                XCTAssertTrue(try model.repository.load().isEmpty)
            }
        }
    }

    func testDisabledHistoryDoesNotBlockExplicitFileAndFolderDelivery() async throws {
        try await MainActor.run {
            try withIsolatedModel(historyEnabled: false) { model in
                for url in [model.root.appendingPathComponent("synthetic-no-history.txt"),
                            model.root.appendingPathComponent("合成无历史文件夹", isDirectory: true)] {
                    let logCount = model.logs.count
                    model.addFiles([url], automatic: false)
                    try assertExplicitDeliveryReachedValidation(model)
                    XCTAssertEqual(model.logs.count, logCount + 2)
                    XCTAssertTrue(model.entries.isEmpty)
                    XCTAssertTrue(try model.repository.load().isEmpty)
                }
            }
        }
    }

    @MainActor
    private func withIsolatedModel(historyEnabled: Bool = true,
                                   _ body: (AppModel) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CopyToolAppTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var preferences = AppPreferences()
        preferences.host = "" // 不访问钥匙串；显式发送在配置验证处终止。
        preferences.shortcuts.enabled = false // 不注册 Carbon 热键或访问前台应用。
        preferences.syncEnabled = true // 旧配置不得重新启用普通复制记录或自动上传。
        preferences.historyEnabled = historyEnabled
        try JSONEncoder().encode(preferences).write(to: root.appendingPathComponent("preferences.json"))
        let model = AppModel(root: root)
        XCTAssertTrue(model.password.isEmpty)
        XCTAssertTrue(model.preferences.syncEnabled)
        XCTAssertEqual(model.preferences.historyEnabled, historyEnabled)
        // 整个验证块只处理合成元数据，不读取或改写系统剪贴板内容。
        try body(model)
    }

    @MainActor
    private func assertOrdinaryCopyIgnored(_ model: AppModel,
                                          file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(model.entries.isEmpty, file: file, line: line)
        XCTAssertTrue(try model.repository.load().isEmpty, file: file, line: line)
        XCTAssertTrue(model.logs.isEmpty, file: file, line: line)
        XCTAssertNil(model.selected, file: file, line: line)
        XCTAssertEqual(model.queued, 0, file: file, line: line)
        XCTAssertTrue(model.activeTransfer.isEmpty, file: file, line: line)
    }

    @MainActor
    private func assertExplicitDeliveryReachedValidation(_ model: AppModel,
                                                        file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(model.message, "未发送：请填写 FTP 服务器地址", file: file, line: line)
        XCTAssertTrue(model.logs.first?.contains("未发送：请填写 FTP 服务器地址") == true, file: file, line: line)
        XCTAssertEqual(model.queued, 0, file: file, line: line)
        XCTAssertTrue(model.activeTransfer.isEmpty, file: file, line: line)
    }
}
