import Foundation

/// Local civil-time policy shared by Watch and iPhone. It does not wake either app.
/// The default zone remains Dallas time even when a device travels to another zone.
struct DailySchedule: Codable, Equatable {
    var enabled = true
    var timeZoneID = "America/Chicago"
    var reminderHour = 8
    var reminderMinute = 0
    var stopHour = 22
    var stopMinute = 0
    var nightOnlyTransfers = true
    var keepLatestArchivedDay = true

    var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.locale = Locale(identifier: "en_US_POSIX")
        // Invalid zones are rejected by the action methods; formatting stays deterministic.
        value.timeZone = TimeZone(identifier: timeZoneID) ?? TimeZone(secondsFromGMT: 0)!
        return value
    }
    var isValid: Bool {
        TimeZone(identifier: timeZoneID) != nil &&
        (0..<24).contains(reminderHour) && (0..<60).contains(reminderMinute) &&
        (0..<24).contains(stopHour) && (0..<60).contains(stopMinute) &&
        reminderHour * 60 + reminderMinute < stopHour * 60 + stopMinute
    }
    func dayStart(_ date: Date) -> Date { calendar.startOfDay(for: date) }
    func dayKey(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
    private func clock(_ day: Date, hour: Int, minute: Int) -> Date? {
        // Calendar arithmetic preserves the local clock across 23/25-hour DST days.
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day,
                      matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
    }
    func startAllowed(at now: Date) -> Bool {
        guard now.timeIntervalSince1970.isFinite else { return false }
        guard enabled else { return true }
        guard isValid,
              let begin = clock(now, hour: reminderHour, minute: reminderMinute),
              let end = clock(now, hour: stopHour, minute: stopMinute) else { return false }
        return now >= begin && now < end
    }
    /// Returns today's stop only for an allowed start. It never schedules the next day.
    func stopDeadline(for start: Date) -> Date? {
        guard enabled, isValid, startAllowed(at: start) else { return nil }
        return clock(start, hour: stopHour, minute: stopMinute)
    }
    /// The most recent scheduled stop, recomputed as a civil time rather than minus 24 hours.
    func latestStop(at now: Date) -> Date? {
        guard enabled, isValid, now.timeIntervalSince1970.isFinite,
              let today = clock(now, hour: stopHour, minute: stopMinute) else { return nil }
        if now >= today { return today }
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: dayStart(now)) else { return nil }
        return clock(yesterday, hour: stopHour, minute: stopMinute)
    }
    func transferWindow(at now: Date) -> Bool {
        guard now.timeIntervalSince1970.isFinite else { return false }
        guard enabled else { return true }
        guard isValid else { return false }
        guard nightOnlyTransfers else { return true }
        let parts = calendar.dateComponents([.hour, .minute], from: now)
        guard let hour = parts.hour, let minute = parts.minute else { return false }
        let current = hour * 60 + minute
        return current >= stopHour * 60 + stopMinute || current < reminderHour * 60 + reminderMinute
    }
    /// This is only the retention-date test. The caller must separately prove that all
    /// required uploads are complete and each old clip still has a verified cloud copy.
    func shouldKeepLocal(clipDate: Date, latestCompleteDay: Date?) -> Bool {
        guard keepLatestArchivedDay, isValid,
              clipDate.timeIntervalSince1970.isFinite,
              let latest = latestCompleteDay, latest.timeIntervalSince1970.isFinite else { return true }
        return dayStart(clipDate) >= dayStart(latest)
    }
}
