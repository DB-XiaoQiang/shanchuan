import AppKit
import CopyToolCore
import UserNotifications
import OSLog

struct SendFailureNotice: Equatable {
    let title: String
    let body: String
}

struct SendFailureNoticePolicy {
    private var lastNotice: Date?

    mutating func notice(for message: String, level: TransferLogEntry.Level, now: Date = Date()) -> SendFailureNotice? {
        let shortcutFailed = message.hasPrefix("快捷键：") && message.contains("未发送")
        let captureFailed = message.hasPrefix("自定义复制未发送：")
        let sendFailed = level == .error && ["发送失败：", "未发送", "图片保存失败：", "准备验证样例失败：", "快捷键初始化失败："].contains { message.hasPrefix($0) }
        guard shortcutFailed || captureFailed || sendFailed else { return nil }
        // One reminder per burst of retries; a later attempt can notify again.
        if let lastNotice, now.timeIntervalSince(lastNotice) < 8 { return nil }
        lastNotice = now
        return SendFailureNotice(title: "闪传未能发送", body: shortcutFailed || captureFailed
            ? "复制未完成，内容未发送。请松开快捷键后重试，或打开闪传查看传输日志。"
            : "文件准备或上传未完成。请打开闪传查看传输日志后重试。")
    }
}

@MainActor final class FailureNotifications: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = FailureNotifications()
    static let openLogs = Notification.Name("CopyToolOpenFailureLogs")
    @Published private(set) var status = "发送失败时提醒；成功发送不通知。"
    private let logger = Logger(subsystem: "local.copytool.independent", category: "FailureNotifications")
    private var authorization: Task<Bool, Never>?

    func configure() {
        UNUserNotificationCenter.current().delegate = self
        Task {
            let allowed = await permission()
            if allowed, ProcessInfo.processInfo.arguments.contains("--test-failure-notification") {
                send(SendFailureNotice(title: "闪传失败通知测试", body: "发送失败时会显示这样的系统提醒。本次未上传任何数据。"))
            }
        }
    }

    func enable() {
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .denied {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            } else { _ = await permission() }
        }
    }

    private func permission() async -> Bool {
        if let authorization { return await authorization.value }
        let task = Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                status = settings.alertSetting == .enabled ? "已允许失败通知。" : "系统横幅未开启，请在系统通知设置中开启。"
                return true
            case .notDetermined:
                do {
                    let granted = try await center.requestAuthorization(options: [.alert, .sound])
                    status = granted ? "已允许失败通知。" : "系统通知未允许，请在系统通知设置中开启闪传。"
                    return granted
                } catch { status = "通知授权请求失败，请在系统通知设置中检查闪传。"; return false }
            default:
                status = "系统通知未允许，请在系统通知设置中开启闪传。"
                return false
            }
        }
        authorization = task
        let allowed = await task.value
        logger.info("Failure notification permission: allowed=\(allowed, privacy: .public)")
        authorization = nil
        return allowed
    }

    func send(_ notice: SendFailureNotice) {
        Task {
            guard await permission() else { return }
            let content = UNMutableNotificationContent()
            content.title = notice.title
            content.body = notice.body
            content.sound = .default
            // Replace the previous failure reminder instead of filling Notification Center.
            let request = UNNotificationRequest(identifier: "copytool-send-failure", content: content, trigger: nil)
            do {
                try await UNUserNotificationCenter.current().add(request)
                logger.info("Failure notification submitted")
            }
            catch { status = "失败通知未能提交，请在系统通知设置中检查闪传。" }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
            NotificationCenter.default.post(name: Self.openLogs, object: nil)
            completionHandler()
        }
    }
}
