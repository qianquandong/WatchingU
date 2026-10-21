import Foundation

/// The recording stop and cloud upload time are separate choices. Uploads stay
/// inside the night window so changing backup time cannot extend microphone use.
struct BackupClock: Codable, Equatable {
    var hour = 22
    var minute = 0
    var label: String { String(format: "%02d:%02d", hour, minute) }
    func isValid(for recording: DailySchedule) -> Bool {
        guard recording.isValid, (0..<24).contains(hour), (0..<60).contains(minute) else { return false }
        let value = hour * 60 + minute
        return value >= recording.stopHour * 60 + recording.stopMinute ||
               value < recording.reminderHour * 60 + recording.reminderMinute
    }
    func due(at now: Date, recording: DailySchedule) -> Bool {
        guard isValid(for: recording), recording.transferWindow(at: now),
              let cutoff = recording.latestStop(at: now) else { return false }
        var day = recording.dayStart(cutoff)
        if hour * 60 + minute < recording.stopHour * 60 + recording.stopMinute {
            guard let tomorrow = recording.calendar.date(byAdding: .day, value: 1, to: day) else { return false }
            day = tomorrow
        }
        guard let start = recording.calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day,
                                                  matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward) else { return false }
        return now >= start
    }
    func nextStart(after now: Date, recording: DailySchedule) -> Date? {
        guard isValid(for: recording), now.timeIntervalSince1970.isFinite else { return nil }
        var parts = DateComponents(); parts.hour = hour; parts.minute = minute; parts.second = 0
        return recording.calendar.nextDate(after: now, matching: parts, matchingPolicy: .nextTime, repeatedTimePolicy: .first)
    }
}
