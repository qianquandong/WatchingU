import Foundation
import UserNotifications

/// One pre-scheduled local reminder survives suspension without polling the battery all day.
@MainActor
final class BackupReminder {
    private struct State: Codable {
        var requestID: String?
        var oldestClipID: UUID?
        var lastScheduledAlert: Date?
    }
    private let stateURL: URL
    private let center = UNUserNotificationCenter.current()
    private var state: State
    private var generation = UUID()

    init(directory: URL) {
        stateURL = directory.appendingPathComponent("backup-reminder.json")
        state = (try? JSONDecoder().decode(State.self, from: Data(contentsOf: stateURL))) ?? State()
    }

    func update(oldest: Clip?, enabled: Bool, now: Date = Date()) async throws {
        if !enabled || oldest == nil {
            guard state.requestID != nil || state.oldestClipID != nil else { return }
            generation = UUID()
            if let id = state.requestID {
                center.removePendingNotificationRequests(withIdentifiers: [id])
                center.removeDeliveredNotifications(withIdentifiers: [id])
            }
            state.requestID = nil; state.oldestClipID = nil
            try persist()
            return
        }
        guard let clip = oldest else { return }
        // Keep the original request/marker after delivery. Repeated foreground entries must
        // not schedule a fresh immediate alert for the same overdue recording.
        guard state.oldestClipID != clip.id || state.requestID == nil else { return }
        guard let due = ChargingBackupPolicy.reminderDate(
            oldestPendingEnd: clip.startedAt.addingTimeInterval(clip.duration),
            lastScheduledAlert: state.lastScheduledAlert) else { return }
        let scheduled = max(due, now.addingTimeInterval(1))
        let id = "daytape.backup.overdue." + UUID().uuidString
        let oldID = state.requestID
        let revision = UUID(); generation = revision
        let previous = state
        state = State(requestID: id, oldestClipID: clip.id, lastScheduledAlert: scheduled)
        do { try persist() }
        catch { state = previous; throw error }
        if let oldID = oldID {
            center.removePendingNotificationRequests(withIdentifiers: [oldID])
            center.removeDeliveredNotifications(withIdentifiers: [oldID])
        }
        let content = UNMutableNotificationContent()
        content.title = "有录音等待云端备份"
        content.body = "请给 iPhone 充电，或打开 DayTape 点“立即备份”。本地录音会保留。"
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, scheduled.timeIntervalSince(now)), repeats: false)
        do {
            try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
            // A newer receive/completion can supersede this add while it is awaiting iOS.
            if generation != revision { center.removePendingNotificationRequests(withIdentifiers: [id]) }
        } catch {
            if generation == revision {
                state.requestID = nil; state.oldestClipID = nil
                state.lastScheduledAlert = previous.lastScheduledAlert
                try? persist()
            }
            throw error
        }
    }

    private func persist() throws {
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: stateURL.path)
    }
}
