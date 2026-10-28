import XCTest
@testable import ClipStorage

final class ChargingBackupPolicyTests: XCTestCase {
    private func permitted(_ power: BackupPowerState, manual: Bool = false, runtime: Bool = true,
                           wifi: Bool = true, wifiOnly: Bool = true, enabled: Bool = true) -> Bool {
        ChargingBackupPolicy.allowsRequest(enabled: enabled, power: power, wifiOnly: wifiOnly,
            wifiAvailable: wifi, runtimeAvailable: runtime, manualBatch: manual)
    }
    func testAutomaticRequiresKnownExternalPower() {
        XCTAssertTrue(permitted(.charging))
        XCTAssertTrue(permitted(.full))
        XCTAssertFalse(permitted(.unplugged))
        XCTAssertFalse(permitted(.unknown))
    }
    func testManualBypassesOnlyPowerAndNeverNetworkRuntimeOrDisabledSetting() {
        XCTAssertTrue(permitted(.unplugged, manual: true))
        XCTAssertTrue(permitted(.unknown, manual: true))
        XCTAssertFalse(permitted(.charging, manual: true, runtime: false))
        XCTAssertFalse(permitted(.unplugged, manual: true, wifi: false))
        XCTAssertFalse(permitted(.charging, manual: true, enabled: false))
        XCTAssertTrue(permitted(.charging, wifi: false, wifiOnly: false))
    }
    func testUnpluggingRevokesAutomaticPermissionButNotExplicitManualBatch() {
        let states: [BackupPowerState] = [.unknown, .charging, .full, .unplugged]
        XCTAssertEqual(states.map { permitted($0) }, [false, true, true, false])
        XCTAssertTrue(permitted(.unplugged, manual: true))
        XCTAssertFalse(permitted(.unplugged))
    }
    func testManualCutoffCannotSweepInNewlyRecordedClips() {
        let pressedAt = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(ChargingBackupPolicy.manualBatchContains(clipEnd: pressedAt, requestedThrough: pressedAt))
        XCTAssertTrue(ChargingBackupPolicy.manualBatchContains(clipEnd: pressedAt.addingTimeInterval(-60), requestedThrough: pressedAt))
        XCTAssertFalse(ChargingBackupPolicy.manualBatchContains(clipEnd: pressedAt.addingTimeInterval(1), requestedThrough: pressedAt))
        XCTAssertFalse(ChargingBackupPolicy.manualBatchContains(clipEnd: pressedAt, requestedThrough: nil))
    }
    func testReminderStartsAfter24HoursAndDoesNotSpamAsOldestClipChanges() {
        let first = Date(timeIntervalSince1970: 1_000)
        let alert = first.addingTimeInterval(86_400)
        XCTAssertEqual(ChargingBackupPolicy.reminderDate(oldestPendingEnd: first, lastScheduledAlert: nil), alert)
        XCTAssertEqual(ChargingBackupPolicy.reminderDate(oldestPendingEnd: first.addingTimeInterval(60), lastScheduledAlert: alert), alert.addingTimeInterval(86_400))
        let later = first.addingTimeInterval(3 * 86_400)
        XCTAssertEqual(ChargingBackupPolicy.reminderDate(oldestPendingEnd: later, lastScheduledAlert: alert), later.addingTimeInterval(86_400))
    }
    func testInvalidDatesNeverAuthorizeManualUploadOrScheduleReminder() {
        let invalid = Date(timeIntervalSince1970: .nan)
        XCTAssertFalse(ChargingBackupPolicy.manualBatchContains(clipEnd: invalid, requestedThrough: Date()))
        XCTAssertFalse(ChargingBackupPolicy.manualBatchContains(clipEnd: Date(), requestedThrough: invalid))
        XCTAssertNil(ChargingBackupPolicy.reminderDate(oldestPendingEnd: invalid, lastScheduledAlert: nil))
    }
    func testReplacingAnUndeliveredReminderDoesNotPostponeTheNextClipTo48Hours() {
        let first = Date(timeIntervalSince1970: 1_000)
        let next = first.addingTimeInterval(60)
        let originalAlert = first.addingTimeInterval(86_400)
        XCTAssertEqual(ChargingBackupPolicy.reminderDate(oldestPendingEnd: next,
            lastScheduledAlert: originalAlert, now: first.addingTimeInterval(300)), next.addingTimeInterval(86_400))
    }
}
