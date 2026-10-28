import XCTest
import CryptoKit
@testable import ClipStorage

final class RecordingContextTests: XCTestCase {
    private func directory() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: path) }
        return path
    }
    private func clip(session: UUID, start: Date, duration: Double = 60) -> Clip {
        Clip(id: UUID(), sessionID: session, startedAt: start, duration: duration,
             byteCount: 500, sha256: String(repeating: "a", count: 64))
    }
    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    func testPrivacySettingsDefaultOffAndRoundTrip() throws {
        let root = try directory(), store = try RecordingContextStore(root: root)
        XCTAssertEqual(try store.settings(), RecordingContextSettings())
        var value = RecordingContextSettings(); value.locationEnabled = true
        try store.saveSettings(value)
        let restored = try RecordingContextStore(root: root).settings()
        XCTAssertTrue(restored.locationEnabled); XCTAssertFalse(restored.healthEnabled)
    }
    func testMarkWaitsForCorrectSessionAndPersistsClipPositionAfterRelaunch() throws {
        let root = try directory(), context = try RecordingContextStore(root: root)
        let session = UUID(), start = Date(timeIntervalSince1970: 1_000)
        let packet = try context.addMark(sessionID: session, at: start.addingTimeInterval(19))
        XCTAssertNil(try context.marks().first?.clipID)
        try context.resolveMarks(clips: [clip(session: UUID(), start: start)])
        XCTAssertNil(try context.marks().first?.clipID)
        let segment = clip(session: session, start: start)
        try context.resolveMarks(clips: [segment])
        let restored = try RecordingContextStore(root: root).marks().first
        XCTAssertEqual(restored?.id, packet.id)
        XCTAssertEqual(restored?.clipID, segment.id)
        XCTAssertEqual(restored?.clipOffset, 19)
        // The position is stored independently of audio cleanup/index availability.
        XCTAssertEqual(try RecordingContextStore(root: root).marks().first?.clipID, segment.id)
    }
    func testMarkAtSegmentBoundaryBindsOnlyToFollowingClip() throws {
        let context = try RecordingContextStore(root: directory())
        let session = UUID(), start = Date(timeIntervalSince1970: 1_000)
        _ = try context.addMark(sessionID: session, at: start.addingTimeInterval(60))
        let first = clip(session: session, start: start)
        let second = clip(session: session, start: start.addingTimeInterval(60))
        try context.resolveMarks(clips: [first]); XCTAssertNil(try context.marks().first?.clipID)
        try context.resolveMarks(clips: [first, second])
        XCTAssertEqual(try context.marks().first?.clipID, second.id)
        XCTAssertEqual(try context.marks().first?.clipOffset, 0)
    }
    func testAudioFramePositionWinsOverWallClockDriftAndRejectsWrongClip() throws {
        let context = try RecordingContextStore(root: directory())
        let session = UUID(), start = Date(timeIntervalSince1970: 1000)
        let segment = clip(session: session, start: start)
        _ = try context.addMark(sessionID: session, at: start.addingTimeInterval(61),
            clipID: segment.id, clipOffset: 59.99)
        try context.resolveMarks(clips: [clip(session: session, start: start.addingTimeInterval(60))])
        XCTAssertNil(try context.marks().first?.clipID)
        try context.resolveMarks(clips: [segment])
        XCTAssertEqual(try context.marks().first?.clipID, segment.id)
        XCTAssertEqual(try context.marks().first?.clipOffset, 59.99)
        try context.deleteContext(for: segment)
        XCTAssertTrue(try context.marks().isEmpty)
    }
    func testInvalidAudioFrameBookmarkCannotBeStored() throws {
        let context = try RecordingContextStore(root: directory()), session = UUID()
        XCTAssertThrowsError(try context.addMark(sessionID: session, at: Date(), clipID: UUID(), clipOffset: .infinity))
        XCTAssertThrowsError(try context.addMark(sessionID: session, at: Date(), clipID: UUID(), clipOffset: nil))
        XCTAssertTrue(try context.marks().isEmpty)
    }
    func testOnlyMatchingDurableReceiptSuppressesTransmissionAndPreservesMark() throws {
        let root = try directory(), sender = try RecordingContextStore(root: root)
        let packet = try sender.addMark(sessionID: UUID(), at: Date(timeIntervalSince1970: 1000))
        let outgoing = try XCTUnwrap(sender.pending().first)
        let receiver = try RecordingContextStore(root: directory())
        XCTAssertThrowsError(try receiver.receive(outgoing.0, id: packet.id, expectedBytes: outgoing.2, expectedHash: String(repeating: "0", count: 64)))
        XCTAssertTrue(try receiver.packets().isEmpty)
        let receipt = try receiver.receive(outgoing.0, id: packet.id, expectedBytes: outgoing.2, expectedHash: outgoing.3)
        XCTAssertEqual(try receiver.packets().map(\.id), [packet.id])
        XCTAssertThrowsError(try sender.acknowledge(ContextReceipt(packetID: packet.id, byteCount: outgoing.2 + 1, sha256: outgoing.3)))
        XCTAssertEqual(try sender.pending().count, 1)
        try sender.acknowledge(receipt)
        XCTAssertTrue(try RecordingContextStore(root: root).pending().isEmpty)
        XCTAssertEqual(try RecordingContextStore(root: root).marks().count, 1)
    }
    func testContextResendIsIdempotentButConflictingIDCannotOverwrite() throws {
        let sender = try RecordingContextStore(root: directory())
        let packet = try sender.addMark(sessionID: UUID(), at: Date(timeIntervalSince1970: 1000))
        let outgoing = try XCTUnwrap(sender.pending().first), receiver = try RecordingContextStore(root: directory())
        let first = try receiver.receive(outgoing.0, id: packet.id, expectedBytes: outgoing.2, expectedHash: outgoing.3)
        XCTAssertEqual(try receiver.receive(outgoing.0, id: packet.id, expectedBytes: outgoing.2, expectedHash: outgoing.3), first)
        let conflict = RecordingContextPacket(id: packet.id, sessionID: packet.sessionID, recordedAt: packet.recordedAt,
            kind: .mark, label: "Changed", coordinate: nil)
        let bytes = try JSONEncoder().encode(conflict), inbox = try directory().appendingPathComponent("incoming.json")
        try bytes.write(to: inbox)
        XCTAssertThrowsError(try receiver.receive(inbox, id: packet.id, expectedBytes: UInt64(bytes.count), expectedHash: digest(bytes)))
        XCTAssertEqual(try receiver.marks().first?.label, "重要时刻")
    }
    func testContextRetryBackoffSurvivesRelaunch() throws {
        let root = try directory(), store = try RecordingContextStore(root: root)
        let packet = try store.addMark(sessionID: UUID(), at: Date(timeIntervalSince1970: 1000))
        let now = Date(timeIntervalSince1970: 2000)
        try store.noteEnqueued(packet.id, at: now)
        let restored = try RecordingContextStore(root: root)
        XCTAssertFalse(restored.mayEnqueue(packet.id, at: now.addingTimeInterval(119)))
        XCTAssertTrue(restored.mayEnqueue(packet.id, at: now.addingTimeInterval(120)))
    }
    func testDeletedContextDoesNotReturnFromLateTransferOrDamageNeighbour() throws {
        let sender = try RecordingContextStore(root: directory()), receiverRoot = try directory()
        let receiver = try RecordingContextStore(root: receiverRoot)
        let session = UUID(), start = Date(timeIntervalSince1970: 1000)
        let deleted = clip(session: session, start: start), neighbour = clip(session: session, start: start.addingTimeInterval(60))
        let mark = try sender.addMark(sessionID: session, at: start.addingTimeInterval(10))
        _ = try receiver.addMark(sessionID: session, at: start.addingTimeInterval(70), label: "Keep")
        let outgoing = try XCTUnwrap(sender.pending().first)
        _ = try receiver.receive(outgoing.0, id: mark.id, expectedBytes: outgoing.2, expectedHash: outgoing.3)
        try receiver.addLocation(sessionID: session, at: start,
            coordinate: RecordedCoordinate(latitude: 32.78, longitude: -96.8, horizontalAccuracy: 1000))
        try receiver.resolveMarks(clips: [deleted, neighbour])
        try receiver.deleteContext(for: deleted)
        XCTAssertEqual(try receiver.marks().map(\.label), ["Keep"])
        XCTAssertNil(try receiver.location(for: deleted))
        XCTAssertNotNil(try receiver.location(for: neighbour))
        _ = try receiver.receive(outgoing.0, id: mark.id, expectedBytes: outgoing.2, expectedHash: outgoing.3)
        let reopened = try RecordingContextStore(root: receiverRoot)
        try reopened.resolveMarks(clips: [deleted, neighbour])
        XCTAssertEqual(try reopened.marks().map(\.label), ["Keep"])
        XCTAssertEqual(try reopened.marks().first?.clipID, neighbour.id)
    }
    func testApproximateLocationsValidateAndCannotCrossRecordingSessions() throws {
        let context = try RecordingContextStore(root: directory())
        let session = UUID(), start = Date(timeIntervalSince1970: 1000)
        let coordinate = RecordedCoordinate(latitude: 32.78, longitude: -96.8, horizontalAccuracy: 1000)
        try context.addLocation(sessionID: session, at: start, coordinate: coordinate)
        XCTAssertNotNil(try context.location(for: clip(session: session, start: start.addingTimeInterval(900))))
        XCTAssertNil(try context.location(for: clip(session: UUID(), start: start)))
        XCTAssertNil(try context.location(for: clip(session: session, start: start.addingTimeInterval(2000))))
        XCTAssertThrowsError(try context.addLocation(sessionID: session, at: start,
            coordinate: RecordedCoordinate(latitude: .nan, longitude: 0, horizontalAccuracy: 1000)))
    }
    func testDuplicateSleepSamplesAreUnionedAndClippedToRecording() {
        let start = Date(timeIntervalSince1970: 1000), end = start.addingTimeInterval(600)
        let ranges = [(start.addingTimeInterval(-100), start.addingTimeInterval(200)),
                      (start, start.addingTimeInterval(200)),
                      (start.addingTimeInterval(100), start.addingTimeInterval(300)),
                      (start.addingTimeInterval(540), start.addingTimeInterval(700))]
        XCTAssertEqual(HealthContextMath.sleepMinutes(intervals: ranges, from: start, to: end), 6)
    }
    func testBatchDrainsSnapshotWithoutAbsorbingNewAudioOrRenewingManualBypass() {
        var batch = WatchTransferBatch()
        let now = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(batch.prepare(at: now, force: false, manualOverride: false, batteryLevel: 0.8, charging: false))
        let originalCutoff = batch.cutoff
        XCTAssertTrue(batch.prepare(at: now.addingTimeInterval(60), force: true, manualOverride: false, batteryLevel: 0.8, charging: false))
        XCTAssertEqual(batch.cutoff, originalCutoff)
        batch.finishIfDrained(audioPending: true, contextPending: false)
        XCTAssertEqual(batch.cutoff, originalCutoff)
        batch.finishIfDrained(audioPending: false, contextPending: false)
        XCTAssertNil(batch.cutoff)
        XCTAssertFalse(batch.prepare(at: now.addingTimeInterval(60), force: false, manualOverride: false, batteryLevel: 0.8, charging: false))
        XCTAssertTrue(batch.prepare(at: now.addingTimeInterval(900), force: false, manualOverride: false, batteryLevel: 0.8, charging: false))
    }
    func testLowBatteryDelaysOnlyAutomaticBatchAndManualExceptionEnds() {
        var batch = WatchTransferBatch()
        let now = Date(timeIntervalSince1970: 1000)
        XCTAssertFalse(batch.prepare(at: now, force: true, manualOverride: false, batteryLevel: 0.1, charging: false))
        XCTAssertTrue(batch.prepare(at: now, force: false, manualOverride: true, batteryLevel: 0.1, charging: false))
        batch.finishIfDrained(audioPending: false, contextPending: false)
        XCTAssertFalse(batch.manual)
        XCTAssertFalse(batch.prepare(at: now.addingTimeInterval(901), force: true, manualOverride: false, batteryLevel: 0.1, charging: false))
        XCTAssertTrue(batch.prepare(at: now.addingTimeInterval(902), force: true, manualOverride: false, batteryLevel: 0.1, charging: true))
    }
}
