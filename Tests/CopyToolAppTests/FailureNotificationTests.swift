import XCTest
import CopyToolCore
@testable import CopyToolApp

final class FailureNotificationTests: XCTestCase {
    func testEnglishFailureClassificationRetainsNotificationsAfterLanguageSwitching() {
        for (message, level) in [
            ("Shortcut: Finder · Copy confirmation timed out; not sent", TransferLogEntry.Level.warning),
            ("Custom copy not sent: the clipboard changed. Copy again.", .warning),
            ("Sending failed: 550", .error),
            ("Verification samples not sent: FTP password is missing", .error),
            ("Could not save image: disk unavailable", .error)
        ] {
            var policy = SendFailureNoticePolicy()
            XCTAssertNotNil(policy.notice(for: message, level: level), message)
        }
        var policy = SendFailureNoticePolicy()
        XCTAssertNil(policy.notice(for: "FTP upload completed", level: .success))
        XCTAssertNil(policy.notice(for: "Transfer cancelled", level: .cancelled))
        XCTAssertNil(policy.notice(for: "Shortcut: Paste action not performed", level: .warning))
    }

    func testShortcutFailuresAndCaptureFailuresNotify() {
        for message in ["快捷键：访达 · 等待快捷键释放期间检测到新的操作，未发送",
                        "快捷键：前台应用 · 复制操作未执行：请等待当前操作或录制结束，未发送",
                        "自定义复制未发送：剪贴板已变化，请重新复制"] {
            var policy = SendFailureNoticePolicy()
            XCTAssertNotNil(policy.notice(for: message, level: .warning))
        }
    }

    func testRetryBurstIsThrottledButLaterFailureNotifies() {
        var policy = SendFailureNoticePolicy()
        let start = Date(timeIntervalSince1970: 100)
        XCTAssertNotNil(policy.notice(for: "发送失败：550", level: .error, now: start))
        XCTAssertNil(policy.notice(for: "快捷键：未发送", level: .warning, now: start.addingTimeInterval(2)))
        XCTAssertNil(policy.notice(for: "发送失败：连接超时", level: .error, now: start.addingTimeInterval(7.9)))
        XCTAssertNotNil(policy.notice(for: "发送失败：连接超时", level: .error, now: start.addingTimeInterval(8)))
    }

    func testSuccessCancellationAndUnrelatedErrorsStayQuiet() {
        var policy = SendFailureNoticePolicy()
        for (text, level) in [("FTP 上传完成", TransferLogEntry.Level.success),
                              ("传输已取消", .cancelled), ("保存历史失败：磁盘错误", .error),
                              ("快捷键：粘贴操作未执行", .warning), ("开始发送：文本", .info)] {
            XCTAssertNil(policy.notice(for: text, level: level))
        }
        XCTAssertNotNil(policy.notice(for: "发送失败：550", level: .error))
    }

    func testNotificationDoesNotExposeFailurePayload() {
        var policy = SendFailureNoticePolicy()
        let notice = policy.notice(for: "发送失败：private-password /private/file.txt 私密文本", level: .error)
        XCTAssertNotNil(notice)
        XCTAssertFalse(notice!.body.contains("private"))
        XCTAssertFalse(notice!.body.contains("私密文本"))
    }

    @MainActor func testModelSendsFailureNoticeWithoutReplayingStoredLogs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var preferences = AppPreferences()
        preferences.shortcuts.enabled = false
        try JSONEncoder().encode(preferences).write(to: root.appendingPathComponent("preferences.json"))
        var notices: [SendFailureNotice] = []
        let model = AppModel(root: root, sendFailureNotice: { notices.append($0) })
        model.recordShortcutStatus("访达 · 复制操作未能确认，未发送")
        XCTAssertEqual(notices.count, 1)
        XCTAssertTrue(model.transferLogs.first!.message.contains("未发送"))
        model.log("发送失败：550", level: .error)
        XCTAssertEqual(notices.count, 1)
        _ = AppModel(root: root, sendFailureNotice: { notices.append($0) })
        XCTAssertEqual(notices.count, 1)
    }
}
