import XCTest
@testable import ClipStorage

/// These tests exercise the actual on-disk day protocol. The payloads deliberately
/// contain opaque bytes: receive/closure verification must not depend on an encoder.
final class DayArchiveTests: XCTestCase {
    private var root: URL!
    private let policy = DailySchedule()
    private let account = "test-google-account"
    private func date(_ local: String) -> Date {
        ISO8601DateFormatter().date(from: local + "-05:00")!
    }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private func store(_ name: String = "phone") throws -> ClipStore {
        let value = try ClipStore(root: root.appendingPathComponent(name))
        try value.saveDailySchedule(policy)
        return value
    }
    private func fixture(_ store: ClipStore, at start: Date, text: String = "opaque-audio") throws -> (URL, Clip) {
        let inbox = root.appendingPathComponent(UUID().uuidString + ".inbox")
        try Data(text.utf8).write(to: inbox)
        let proof = try store.hash(inbox)
        return (inbox, Clip(id: UUID(), sessionID: UUID(), startedAt: start, duration: 60,
                            byteCount: proof.0, sha256: proof.1))
    }
    @discardableResult
    private func receive(_ store: ClipStore, at start: Date, text: String = "opaque-audio") throws -> Clip {
        let (inbox, clip) = try fixture(store, at: start, text: text)
        _ = try store.receive(inbox, clip: clip)
        return clip
    }
    private func cloud(_ store: ClipStore, _ clip: Clip, accountID: String? = nil) throws {
        let proof = CloudReceipt(clipID: clip.id, fileID: "audio-" + clip.id.uuidString,
                                 metadataFileID: "sidecar-" + clip.id.uuidString,
                                 accountID: accountID ?? account, byteCount: clip.byteCount,
                                 sha256: clip.sha256, verifiedAt: date("2026-10-20T01:00:00"))
        try store.commitCloudReceipt(proof, clip: clip, purge: false, uploadActive: false)
    }
    private func closure(_ clips: [Clip], day: String = "2026-10-18") -> DayClosure {
        DayClosure(dayKey: day, dayStart: date(day + "T00:00:00"), cutoff: date(day + "T22:00:00"),
                   closedAt: date(day + "T22:05:00"), timeZoneID: policy.timeZoneID, clips: clips)
    }
    private func deliver(_ value: DayClosure, to store: ClipStore) throws {
        let inbox = root.appendingPathComponent(UUID().uuidString + ".seal-inbox")
        try JSONEncoder().encode(value).write(to: inbox)
        let proof = try store.hash(inbox)
        try store.receiveDayClosure(inbox, expectedHash: proof.1, expectedBytes: proof.0)
    }

    func testCloudReceiptsWithoutWatchClosureCannotCompleteDay() throws {
        let phone = try store()
        let clip = try receive(phone, at: date("2026-10-18T10:00:00"))
        try cloud(phone, clip)
        XCTAssertTrue(try phone.completeDays(accountID: account, policy: policy).isEmpty)
        XCTAssertTrue(phone.hasLocalAudio(clip.id))
    }

    func testMissingClipOrMissingCloudReceiptKeepsDayIncomplete() throws {
        let phone = try store()
        let first = try receive(phone, at: date("2026-10-18T10:00:00"))
        let (secondInbox, second) = try fixture(phone, at: date("2026-10-18T11:00:00"))
        try cloud(phone, first)
        try deliver(closure([first, second]), to: phone)
        XCTAssertTrue(try phone.completeDays(accountID: account, policy: policy).isEmpty)
        _ = try phone.receive(secondInbox, clip: second)
        XCTAssertTrue(try phone.completeDays(accountID: account, policy: policy).isEmpty)
        try cloud(phone, second)
        XCTAssertEqual(try phone.completeDays(accountID: account, policy: policy).map(\.dayKey), ["2026-10-18"])
    }

    func testMatchingCompleteDaysAreSortedAndKeepNewestAudio() throws {
        let phone = try store()
        let older = try receive(phone, at: date("2026-10-18T10:00:00"))
        let newer = try receive(phone, at: date("2026-10-19T10:00:00"))
        for clip in [older, newer] { try cloud(phone, clip) }
        try deliver(closure([newer], day: "2026-10-19"), to: phone)
        try deliver(closure([older]), to: phone)
        let complete = try phone.completeDays(accountID: account, policy: policy)
        XCTAssertEqual(complete.map(\.dayKey), ["2026-10-18", "2026-10-19"])
        XCTAssertFalse(policy.shouldKeepLocal(clipDate: older.startedAt, latestCompleteDay: complete.last?.dayStart))
        XCTAssertTrue(policy.shouldKeepLocal(clipDate: newer.startedAt, latestCompleteDay: complete.last?.dayStart))
        // Completion and eligibility are proofs; they do not themselves remove local audio.
        XCTAssertTrue(phone.hasLocalAudio(older.id)); XCTAssertTrue(phone.hasLocalAudio(newer.id))
    }

    func testCloudProofForDifferentAccountCannotCompleteDay() throws {
        let phone = try store()
        let clip = try receive(phone, at: date("2026-10-18T10:00:00"))
        try deliver(closure([clip]), to: phone)
        try cloud(phone, clip, accountID: "another-google-account")
        XCTAssertTrue(try phone.completeDays(accountID: account, policy: policy).isEmpty)
        try cloud(phone, clip)
        XCTAssertEqual(try phone.completeDays(accountID: account, policy: policy).count, 1)
    }

    func testUnexpectedLateClipBlocksAnOtherwiseCompleteDay() throws {
        let phone = try store()
        let first = try receive(phone, at: date("2026-10-18T10:00:00"))
        try cloud(phone, first); try deliver(closure([first]), to: phone)
        XCTAssertEqual(try phone.completeDays(accountID: account, policy: policy).count, 1)
        let late = try receive(phone, at: date("2026-10-18T11:00:00"), text: "late-segment")
        try cloud(phone, late)
        XCTAssertTrue(phone.dayIsBlocked("2026-10-18"))
        XCTAssertTrue(try phone.completeDays(accountID: account, policy: policy).isEmpty)
        XCTAssertTrue(phone.hasLocalAudio(first.id)); XCTAssertTrue(phone.hasLocalAudio(late.id))
    }

    func testConflictingClosureRevisionIsPersistentlyBlocked() throws {
        let phone = try store()
        let first = try receive(phone, at: date("2026-10-18T10:00:00"))
        let (_, other) = try fixture(phone, at: date("2026-10-18T11:00:00"), text: "different-segment")
        let original = closure([first])
        try cloud(phone, first); try deliver(original, to: phone)
        XCTAssertThrowsError(try deliver(closure([first, other]), to: phone))
        let reopened = try ClipStore(root: phone.root)
        XCTAssertTrue(reopened.dayIsBlocked(original.dayKey))
        XCTAssertEqual(try reopened.dayClosures().first?.1.revision, original.revision)
        XCTAssertTrue(try reopened.completeDays(accountID: account, policy: policy).isEmpty)
        // Re-delivery of the original snapshot must not clear a conflict marker.
        try deliver(original, to: reopened)
        XCTAssertTrue(reopened.dayIsBlocked(original.dayKey))
    }

    func testDuplicateClosureAndDayAcknowledgementAreIdempotent() throws {
        let phone = try store()
        let clip = try receive(phone, at: date("2026-10-18T10:00:00"))
        let value = closure([clip])
        try cloud(phone, clip); try deliver(value, to: phone); try deliver(value, to: phone)
        XCTAssertEqual(try phone.dayClosures().count, 1)
        XCTAssertEqual(try phone.completeDays(accountID: account, policy: policy).count, 1)
        XCTAssertFalse(phone.dayIsBlocked(value.dayKey))
        XCTAssertFalse(phone.isDayConfirmed(value))
        XCTAssertThrowsError(try phone.acknowledgeDay(value.dayKey, revision: "wrong-revision"))
        try phone.acknowledgeDay(value.dayKey, revision: value.revision)
        try phone.acknowledgeDay(value.dayKey, revision: value.revision)
        XCTAssertTrue(phone.isDayConfirmed(value))
    }

    func testWatchLedgerSurvivesClipAcknowledgementCleanup() throws {
        let watch = try store("watch")
        let clip = try receive(watch, at: date("2026-10-18T10:00:00"))
        try watch.appendDayLedger(clip)
        try watch.appendDayLedger(clip)
        try watch.acknowledge(Receipt(clip: clip))
        XCTAssertFalse(watch.hasLocalAudio(clip.id))
        XCTAssertTrue(try watch.clips().isEmpty)
        let reopened = try ClipStore(root: watch.root)
        try reopened.sealDueDays(now: date("2026-10-18T22:05:00"))
        let value = try XCTUnwrap(reopened.dayClosures().first?.1)
        XCTAssertEqual(value.clips.count, 1)
        XCTAssertEqual(value.clips.first?.id, clip.id)
        XCTAssertEqual(value.revision, DayClosure.digest([clip]))
    }

    func testActiveCaptureAndUnresolvedDraftBothPreventDaySeal() throws {
        let watch = try store("watch")
        let clip = try receive(watch, at: date("2026-10-18T10:00:00"))
        try watch.appendDayLedger(clip)
        try watch.beginCaptureMarker(sessionID: clip.sessionID, at: clip.startedAt)
        let afterStop = date("2026-10-18T22:05:00")
        try watch.sealDueDays(now: afterStop)
        XCTAssertTrue(try watch.dayClosures().isEmpty)
        try watch.finishCaptureMarker()
        let draft = CaptureDraft(id: UUID(), sessionID: clip.sessionID, startedAt: clip.startedAt)
        try watch.writeDraft(draft)
        try watch.sealDueDays(now: afterStop)
        XCTAssertTrue(try watch.dayClosures().isEmpty)
        try FileManager.default.removeItem(at: watch.root.appendingPathComponent(draft.id.uuidString + ".draft.json"))
        try watch.sealDueDays(now: afterStop)
        XCTAssertEqual(try watch.dayClosures().count, 1)
    }

    func testClipEndingAfterCutoffInvalidatesClosure() throws {
        let phone = try store()
        let clip = try receive(phone, at: date("2026-10-18T21:59:30"))
        let invalid = closure([clip])
        XCTAssertFalse(invalid.isValid)
        XCTAssertThrowsError(try deliver(invalid, to: phone))
        XCTAssertTrue(try phone.dayClosures().isEmpty)
        XCTAssertTrue(try phone.completeDays(accountID: account, policy: policy).isEmpty)
        XCTAssertTrue(phone.hasLocalAudio(clip.id))
    }
}
