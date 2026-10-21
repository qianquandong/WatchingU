import XCTest
@testable import ClipStorage

final class ScheduleTests: XCTestCase {
    private func instant(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }
    func testDefaultStartAndStopBoundaries() {
        let schedule = DailySchedule()
        XCTAssertTrue(schedule.isValid)
        // October in Dallas is UTC-5: local 08:00 is 13:00Z and local 22:00 is 03:00Z.
        XCTAssertFalse(schedule.startAllowed(at: instant("2026-10-20T12:59:59Z")))
        XCTAssertTrue(schedule.startAllowed(at: instant("2026-10-20T13:00:00Z")))
        XCTAssertTrue(schedule.startAllowed(at: instant("2026-10-21T02:59:59Z")))
        XCTAssertFalse(schedule.startAllowed(at: instant("2026-10-21T03:00:00Z")))
        XCTAssertEqual(schedule.stopDeadline(for: instant("2026-10-20T13:00:00Z")), instant("2026-10-21T03:00:00Z"))
        XCTAssertNil(schedule.stopDeadline(for: instant("2026-10-20T12:59:59Z")))
        XCTAssertNil(schedule.stopDeadline(for: instant("2026-10-21T03:00:00Z")))
    }
    func testNightWindowIncludesStopAndExcludesMorning() {
        let schedule = DailySchedule()
        XCTAssertFalse(schedule.transferWindow(at: instant("2026-10-21T02:59:59Z")))
        XCTAssertTrue(schedule.transferWindow(at: instant("2026-10-21T03:00:00Z")))
        XCTAssertTrue(schedule.transferWindow(at: instant("2026-10-21T12:59:59Z")))
        XCTAssertFalse(schedule.transferWindow(at: instant("2026-10-21T13:00:00Z")))
        XCTAssertFalse(schedule.transferWindow(at: instant("2026-10-21T18:00:00Z")))
    }
    func testLatestStopIsPriorEveningUntilTodaysStop() {
        let schedule = DailySchedule()
        let expected = instant("2026-10-20T03:00:00Z") // October 19 at 22:00 Dallas.
        XCTAssertEqual(schedule.latestStop(at: instant("2026-10-20T13:00:00Z")), expected)
        XCTAssertEqual(schedule.latestStop(at: instant("2026-10-21T02:59:59Z")), expected)
        XCTAssertEqual(schedule.latestStop(at: instant("2026-10-21T03:00:00Z")), instant("2026-10-21T03:00:00Z"))
    }
    func testSpringDSTMaintainsTwentyTwoLocalTime() {
        let schedule = DailySchedule()
        let before = schedule.stopDeadline(for: instant("2026-03-07T14:00:00Z"))!
        let after = schedule.stopDeadline(for: instant("2026-03-08T13:00:00Z"))!
        XCTAssertEqual(before, instant("2026-03-08T04:00:00Z"))
        XCTAssertEqual(after, instant("2026-03-09T03:00:00Z"))
        XCTAssertEqual(after.timeIntervalSince(before), 23 * 3600)
        XCTAssertEqual(schedule.calendar.component(.hour, from: after), 22)
        XCTAssertEqual(schedule.latestStop(at: instant("2026-03-08T13:00:00Z")), before)
    }
    func testFallDSTMaintainsTwentyTwoLocalTime() {
        let schedule = DailySchedule()
        let before = schedule.stopDeadline(for: instant("2026-10-31T13:00:00Z"))!
        let after = schedule.stopDeadline(for: instant("2026-11-01T14:00:00Z"))!
        XCTAssertEqual(before, instant("2026-11-01T03:00:00Z"))
        XCTAssertEqual(after, instant("2026-11-02T04:00:00Z"))
        XCTAssertEqual(after.timeIntervalSince(before), 25 * 3600)
        XCTAssertEqual(schedule.calendar.component(.hour, from: after), 22)
        XCTAssertEqual(schedule.latestStop(at: instant("2026-11-01T14:00:00Z")), before)
    }
    func testDayKeysFollowDallasMidnightAndSortAcrossYear() {
        let schedule = DailySchedule()
        XCTAssertEqual(schedule.dayKey(instant("2026-10-21T04:59:59Z")), "2026-10-20")
        XCTAssertEqual(schedule.dayKey(instant("2026-10-21T05:00:00Z")), "2026-10-21")
        let dates = ["2026-12-31T18:00:00Z", "2027-01-01T18:00:00Z"].map(instant)
        XCTAssertLessThan(schedule.dayKey(dates[0]), schedule.dayKey(dates[1]))
        XCTAssertEqual(schedule.dayStart(instant("2026-10-21T03:00:00Z")), instant("2026-10-20T05:00:00Z"))
    }
    func testInvalidSettingsCannotStartTransferOrProduceCutoff() {
        let date = instant("2026-10-20T18:00:00Z")
        var variants: [DailySchedule] = []
        var value = DailySchedule(); value.reminderHour = -1; variants.append(value)
        value = DailySchedule(); value.stopHour = 24; variants.append(value)
        value = DailySchedule(); value.reminderMinute = 60; variants.append(value)
        value = DailySchedule(); value.stopMinute = -1; variants.append(value)
        value = DailySchedule(); value.stopHour = 8; variants.append(value)
        value = DailySchedule(); value.stopHour = 7; variants.append(value)
        value = DailySchedule(); value.timeZoneID = "Invalid/TimeZone"; variants.append(value)
        for schedule in variants {
            XCTAssertFalse(schedule.isValid)
            XCTAssertFalse(schedule.startAllowed(at: date))
            XCTAssertFalse(schedule.transferWindow(at: date))
            XCTAssertNil(schedule.stopDeadline(for: date))
            XCTAssertNil(schedule.latestStop(at: date))
            XCTAssertTrue(schedule.shouldKeepLocal(clipDate: date, latestCompleteDay: date.addingTimeInterval(86400)))
        }
    }
    func testDisabledScheduleAndOptionalDaytimeTransfer() {
        let date = instant("2026-10-20T06:00:00Z") // 01:00 Dallas.
        var schedule = DailySchedule(); schedule.enabled = false
        XCTAssertTrue(schedule.startAllowed(at: date))
        XCTAssertTrue(schedule.transferWindow(at: date))
        XCTAssertNil(schedule.stopDeadline(for: date))
        XCTAssertNil(schedule.latestStop(at: date))
        schedule.enabled = true; schedule.nightOnlyTransfers = false
        XCTAssertTrue(schedule.transferWindow(at: instant("2026-10-20T18:00:00Z")))
    }
    func testRetentionOnlyReleasesDaysOlderThanCompletedBoundary() {
        var schedule = DailySchedule()
        let previous = instant("2026-10-19T18:00:00Z")
        let latest = instant("2026-10-20T18:00:00Z")
        let newer = instant("2026-10-21T18:00:00Z")
        XCTAssertTrue(schedule.shouldKeepLocal(clipDate: previous, latestCompleteDay: nil))
        XCTAssertFalse(schedule.shouldKeepLocal(clipDate: previous, latestCompleteDay: latest))
        XCTAssertTrue(schedule.shouldKeepLocal(clipDate: instant("2026-10-20T05:00:00Z"), latestCompleteDay: latest))
        XCTAssertTrue(schedule.shouldKeepLocal(clipDate: latest, latestCompleteDay: latest))
        XCTAssertTrue(schedule.shouldKeepLocal(clipDate: newer, latestCompleteDay: latest))
        schedule.keepLatestArchivedDay = false
        XCTAssertTrue(schedule.shouldKeepLocal(clipDate: previous, latestCompleteDay: latest))
    }
    func testScheduleRoundTripPreservesZoneAndOptions() throws {
        var schedule = DailySchedule()
        schedule.reminderMinute = 15; schedule.stopMinute = 30
        schedule.nightOnlyTransfers = false
        let data = try JSONEncoder().encode(schedule)
        XCTAssertEqual(try JSONDecoder().decode(DailySchedule.self, from: data), schedule)
    }
}
