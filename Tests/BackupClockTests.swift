import XCTest
@testable import ClipStorage

final class BackupClockTests: XCTestCase {
    private let recording = DailySchedule()
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    func testDefaultBackupStartsAtStopAndClosesAtMorning() {
        let clock = BackupClock()
        XCTAssertFalse(clock.due(at: date("2026-10-20T21:59:59-05:00"), recording: recording))
        XCTAssertTrue(clock.due(at: date("2026-10-20T22:00:00-05:00"), recording: recording))
        XCTAssertTrue(clock.due(at: date("2026-10-21T07:59:59-05:00"), recording: recording))
        XCTAssertFalse(clock.due(at: date("2026-10-21T08:00:00-05:00"), recording: recording))
    }
    func testLaterBackupDoesNotStartAtRecordingStop() {
        let clock = BackupClock(hour: 23, minute: 0)
        XCTAssertTrue(clock.isValid(for: recording))
        XCTAssertFalse(clock.due(at: date("2026-10-20T22:00:00-05:00"), recording: recording))
        XCTAssertFalse(clock.due(at: date("2026-10-20T22:59:59-05:00"), recording: recording))
        XCTAssertTrue(clock.due(at: date("2026-10-20T23:00:00-05:00"), recording: recording))
    }
    func testAfterMidnightBackupBelongsToPreviousRecordingDay() {
        let clock = BackupClock(hour: 0, minute: 30)
        XCTAssertFalse(clock.due(at: date("2026-10-20T23:50:00-05:00"), recording: recording))
        XCTAssertFalse(clock.due(at: date("2026-10-21T00:29:59-05:00"), recording: recording))
        XCTAssertTrue(clock.due(at: date("2026-10-21T00:30:00-05:00"), recording: recording))
    }
    func testDaytimeAndInvalidClocksCannotEnableBackup() {
        for clock in [BackupClock(hour: 8, minute: 0), BackupClock(hour: 20, minute: 0),
                      BackupClock(hour: -1, minute: 0), BackupClock(hour: 24, minute: 0), BackupClock(hour: 22, minute: 60)] {
            XCTAssertFalse(clock.isValid(for: recording))
            XCTAssertFalse(clock.due(at: date("2026-10-20T23:00:00-05:00"), recording: recording))
            XCTAssertNil(clock.nextStart(after: date("2026-10-20T12:00:00-05:00"), recording: recording))
        }
    }
    func testNextStartUsesDallasTime() {
        let clock = BackupClock(hour: 23, minute: 0)
        XCTAssertEqual(clock.nextStart(after: date("2026-10-20T12:00:00-05:00"), recording: recording), date("2026-10-20T23:00:00-05:00"))
        XCTAssertEqual(clock.nextStart(after: date("2026-10-20T23:00:01-05:00"), recording: recording), date("2026-10-21T23:00:00-05:00"))
    }
    func testMissingOldUploadClockMigratesToRecordingStop() throws {
        var value = ArchiveSettings()
        let legacy = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(ArchiveSettings.self, from: legacy)
        XCTAssertEqual(decoded.resolvedUploadClock(for: recording), BackupClock())
        value.uploadClock = BackupClock(hour: 1, minute: 15)
        let roundTrip = try JSONDecoder().decode(ArchiveSettings.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(roundTrip.uploadClock, value.uploadClock)
    }
    func testDSTGapAndRepeatedHourStayInNightWindow() {
        let spring = BackupClock(hour: 2, minute: 30)
        XCTAssertFalse(spring.due(at: date("2026-03-08T01:59:59-06:00"), recording: recording))
        XCTAssertTrue(spring.due(at: date("2026-03-08T03:00:00-05:00"), recording: recording))
        let fall = BackupClock(hour: 1, minute: 30)
        XCTAssertTrue(fall.due(at: date("2026-11-01T01:30:00-05:00"), recording: recording))
        XCTAssertTrue(fall.due(at: date("2026-11-01T01:30:00-06:00"), recording: recording))
    }
}
