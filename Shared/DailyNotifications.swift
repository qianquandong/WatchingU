import Foundation
import UserNotifications

/// Install from the user's setup action. Delivery is subject to system notification settings.
/// A notification response only asks the watch UI to start; it never opens the microphone here.
final class DailyNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = DailyNotifications()
    static let morningID = "daytape.morning"
    static let morningCategory = "DAYTAPE_MORNING"
    static let startAction = "DAYTAPE_START"

    var onError: ((Error) -> Void)?
    private let center: UNUserNotificationCenter

    private override init() {
        center = .current()
        super.init()
        // UNUserNotificationCenter holds its delegate weakly; the singleton remains alive.
        center.delegate = self
    }

    enum SetupError: LocalizedError {
        case permissionDenied, invalidSchedule
        var errorDescription: String? {
            switch self {
            case .permissionDenied: return "通知权限未开启。请在系统设置中允许 DayTape 通知；录音仍需你在手表上开始。"
            case .invalidSchedule: return "提醒或停止时间无效，未安装每日提醒。"
            }
        }
    }

    /// Call only after an explicit setup/permission action, rather than every app launch.
    func configure(_ schedule: DailySchedule, morningReminder: Bool) async throws {
        let allowed = try await center.requestAuthorization(options: [.alert, .sound])
        guard allowed else { throw SetupError.permissionDenied }
        try await install(schedule, morningReminder: morningReminder)
    }

    /// Restore the request without requesting permission or interpreting request creation as delivery.
    /// The iPhone passes morningReminder=false so it does not duplicate the watch's reminder.
    func install(_ schedule: DailySchedule, morningReminder: Bool) async throws {
        center.removePendingNotificationRequests(withIdentifiers: [Self.morningID])
        guard schedule.enabled, morningReminder else { return }
        guard schedule.isValid else { throw SetupError.invalidSchedule }
        await registerMorningCategory()

        let content = UNMutableNotificationContent()
        content.title = "开始今天的录音"
        let stop = String(format: "%02d:%02d", schedule.stopHour, schedule.stopMinute)
        content.body = "点“开始录音”打开 DayTape，在前台开始记录；今天计划 \(stop) 停止。"
        content.sound = .default
        content.categoryIdentifier = Self.morningCategory
        content.userInfo = ["kind": "morning", "scheduleTimeZone": schedule.timeZoneID]

        var components = DateComponents()
        components.calendar = schedule.calendar
        components.timeZone = schedule.calendar.timeZone
        components.hour = schedule.reminderHour
        components.minute = schedule.reminderMinute
        components.second = 0
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        try await center.add(UNNotificationRequest(identifier: Self.morningID, content: content, trigger: trigger))
    }

    private func registerMorningCategory() async {
        let existing: Set<UNNotificationCategory> = await withCheckedContinuation { continuation in
            center.getNotificationCategories { continuation.resume(returning: $0) }
        }
        let start = UNNotificationAction(identifier: Self.startAction, title: "开始录音", options: [.foreground])
        let morning = UNNotificationCategory(identifier: Self.morningCategory, actions: [start], intentIdentifiers: [], options: [])
        var categories = Set(existing.filter { $0.identifier != Self.morningCategory })
        categories.insert(morning)
        center.setNotificationCategories(categories)
    }

    /// Used only for actual stop/queue/completion events, not as evidence that uploads completed.
    func notify(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.sound = .default
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { [weak self] error in
            guard let error = error else { return }
            DispatchQueue.main.async { self?.onError?(error) }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let request = response.notification.request
        guard request.identifier == Self.morningID,
              request.content.categoryIdentifier == Self.morningCategory,
              response.actionIdentifier == Self.startAction || response.actionIdentifier == UNNotificationDefaultActionIdentifier else {
            completionHandler(); return
        }
        let requestedAt = Date()
        let deliveredAt = response.notification.date
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .dailyStartRequested, object: nil,
                userInfo: ["requestedAt": requestedAt, "deliveredAt": deliveredAt, "requestIdentifier": request.identifier])
            completionHandler()
        }
    }
}

extension Notification.Name {
    static let dailyStartRequested = Notification.Name("daytape.daily.start.requested")
}
