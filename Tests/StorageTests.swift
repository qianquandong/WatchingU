import XCTest
@testable import ClipStorage

final class StorageTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private func fixture(_ store: ClipStore, id: UUID = UUID(), content: String = "opaque-protocol-test-payload") throws -> (URL, Clip) {
        let url = root.appendingPathComponent(UUID().uuidString + ".test-inbox")
        try Data(content.utf8).write(to: url)
        let pair = try store.hash(url)
        return (url, Clip(id: id, sessionID: UUID(), startedAt: Date(), duration: 1,
                          byteCount: pair.0, sha256: pair.1))
    }
    func testLostAcknowledgementRetryIsIdempotent() throws {
        let store = try ClipStore(root: root.appendingPathComponent("receiver"))
        let (inbox, clip) = try fixture(store)
        let first = try store.receive(inbox, clip: clip)
        let second = try store.receive(inbox, clip: clip)
        XCTAssertTrue(first.matches(clip)); XCTAssertTrue(second.matches(clip))
        XCTAssertEqual(try store.clips().count, 1)
        XCTAssertEqual(try Data(contentsOf: store.audioURL(clip.id)), try Data(contentsOf: inbox))
    }
    func testCorruptTransferProducesNoArchive() throws {
        let store = try ClipStore(root: root.appendingPathComponent("receiver"))
        let (inbox, clip) = try fixture(store)
        try Data("corruption".utf8).write(to: inbox)
        XCTAssertThrowsError(try store.receive(inbox, clip: clip))
        XCTAssertEqual(try store.clips().count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.audioURL(clip.id).path))
    }
    func testConflictingDuplicateNeverOverwritesOriginal() throws {
        let store = try ClipStore(root: root.appendingPathComponent("receiver"))
        let (inbox, clip) = try fixture(store)
        _ = try store.receive(inbox, clip: clip)
        let saved = try Data(contentsOf: store.audioURL(clip.id))
        let (otherInbox, otherClip) = try fixture(store, id: clip.id, content: "different bytes")
        XCTAssertThrowsError(try store.receive(otherInbox, clip: otherClip))
        XCTAssertEqual(try Data(contentsOf: store.audioURL(clip.id)), saved)
    }
    func testManifestFailureCannotProduceReceiptAndRetryRepairsOrphan() throws {
        let store = try ClipStore(root: root.appendingPathComponent("receiver"))
        let (inbox, clip) = try fixture(store)
        let blocker = store.root.appendingPathComponent(clip.id.uuidString + ".clip.json")
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.receive(inbox, clip: clip))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.audioURL(clip.id).path))
        try FileManager.default.removeItem(at: blocker)
        XCTAssertTrue(try store.receive(inbox, clip: clip).matches(clip))
        XCTAssertEqual(try store.clips().count, 1)
    }
    func testWrongReceiptRetainsSourceAndCorrectReceiptCleansIt() throws {
        let store = try ClipStore(root: root.appendingPathComponent("sender"))
        let (inbox, clip) = try fixture(store)
        _ = try store.receive(inbox, clip: clip)
        let wrong = Clip(id: clip.id, sessionID: clip.sessionID, startedAt: clip.startedAt,
                         duration: clip.duration, byteCount: clip.byteCount + 1, sha256: clip.sha256)
        XCTAssertThrowsError(try store.acknowledge(Receipt(clip: wrong)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.audioURL(clip.id).path))
        try store.acknowledge(Receipt(clip: clip))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.audioURL(clip.id).path))
        XCTAssertEqual(try store.pending().count, 0)
        // Delayed duplicate ACK is harmless.
        XCTAssertNoThrow(try store.acknowledge(Receipt(clip: clip)))
    }
    func testExplicitDeletionDoesNotResurrectAfterLateRetransmission() throws {
        let store = try ClipStore(root: root.appendingPathComponent("phone"))
        let (inbox, clip) = try fixture(store); _ = try store.receive(inbox, clip: clip)
        try store.deleteByUser(clip)
        XCTAssertFalse(store.hasLocalAudio(clip.id)); XCTAssertTrue(try store.clips().isEmpty)
        let reopened = try ClipStore(root: store.root)
        XCTAssertTrue(try reopened.receive(inbox, clip: clip).matches(clip))
        XCTAssertFalse(reopened.hasLocalAudio(clip.id)); XCTAssertTrue(try reopened.clips().isEmpty)
        let (badInbox, badClip) = try fixture(store, id: clip.id, content: "conflicting retransmission")
        XCTAssertThrowsError(try reopened.receive(badInbox, clip: badClip))
    }
    func testTombstoneHidesFilesLeftByInterruptedDeletionAndCleanupIsRetryable() throws {
        let store = try ClipStore(root: root.appendingPathComponent("phone"))
        let (inbox, clip) = try fixture(store); _ = try store.receive(inbox, clip: clip)
        try store.commitCloudReceipt(cloud(clip), clip: clip, purge: false, uploadActive: false)
        let tombstone = store.root.appendingPathComponent(clip.id.uuidString + ".deleted.json")
        try JSONEncoder().encode(Receipt(clip: clip)).write(to: tombstone, options: .atomic)
        // Reopen at the exact crash point: receipt is durable, all original files still exist.
        let reopened = try ClipStore(root: store.root)
        XCTAssertEqual(try reopened.deletedClipIDs(), Set([clip.id]))
        XCTAssertTrue(try reopened.clips().isEmpty)
        XCTAssertFalse(reopened.hasLocalAudio(clip.id))
        XCTAssertFalse(reopened.retainAudio(clip.id))
        XCTAssertNil(reopened.cloudReceipt(clip.id))
        XCTAssertTrue(try reopened.pendingDeletedAudioIDs().contains(clip.id))
        try reopened.purgeDeletedAudio()
        XCTAssertTrue(try reopened.pendingDeletedAudioIDs().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reopened.audioURL(clip.id).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tombstone.path))
        XCTAssertNoThrow(try reopened.purgeDeletedAudio())
    }
    func testDeletionFailureInvalidatesCachedLibraryRowBeforePhysicalCleanupFinishes() throws {
        let store = try ClipStore(root: root.appendingPathComponent("phone"))
        let (inbox, clip) = try fixture(store); _ = try store.receive(inbox, clip: clip)
        XCTAssertEqual(try store.clips().count, 1) // Prime both live and deletion caches.
        let blocker = store.root.appendingPathComponent(clip.id.uuidString + ".cloud.json")
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.deleteByUser(clip))
        XCTAssertTrue(try store.clips().isEmpty)
        XCTAssertFalse(store.hasLocalAudio(clip.id))
        XCTAssertFalse(store.retainAudio(clip.id))
        XCTAssertTrue(try store.pendingDeletedAudioIDs().contains(clip.id))
        try FileManager.default.removeItem(at: blocker)
        try store.purgeDeletedAudio()
        XCTAssertTrue(try store.pendingDeletedAudioIDs().isEmpty)
        XCTAssertEqual(try ClipStore(root: store.root).deletedClipIDs(), Set([clip.id]))
    }
    func testMismatchedDeletedReceiptIsRejectedAndAudioAccessFailsClosed() throws {
        let store = try ClipStore(root: root.appendingPathComponent("phone"))
        let (inbox, clip) = try fixture(store); _ = try store.receive(inbox, clip: clip)
        try JSONEncoder().encode(Receipt(clip: clip)).write(to:
            store.root.appendingPathComponent(UUID().uuidString + ".deleted.json"))
        let reopened = try ClipStore(root: store.root)
        XCTAssertThrowsError(try reopened.deletedClipIDs())
        XCTAssertThrowsError(try reopened.clips())
        XCTAssertFalse(reopened.hasLocalAudio(clip.id))
        XCTAssertFalse(reopened.retainAudio(clip.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: reopened.audioURL(clip.id).path))
    }
    func testPendingTranscriptionSurvivesVerifiedCloudCleanup() throws {
        let store = try ClipStore(root: root.appendingPathComponent("phone"))
        let (inbox, clip) = try fixture(store); _ = try store.receive(inbox, clip: clip)
        let hold = store.root.appendingPathComponent(clip.id.uuidString + ".processing-hold")
        try Data().write(to: hold)
        try store.commitCloudReceipt(cloud(clip), clip: clip, purge: true, uploadActive: false)
        XCTAssertTrue(store.hasLocalAudio(clip.id))
        try FileManager.default.removeItem(at: hold)
        try store.commitCloudReceipt(cloud(clip), clip: clip, purge: true, uploadActive: false)
        XCTAssertFalse(store.hasLocalAudio(clip.id))
    }
    private func cloud(_ clip: Clip, bytes: UInt64? = nil) -> CloudReceipt {
        CloudReceipt(clipID: clip.id, fileID: "audio", metadataFileID: "metadata", accountID: "account",
                     byteCount: bytes ?? clip.byteCount, sha256: clip.sha256, verifiedAt: Date())
    }
    func testCloudEvictionRequiresMatchingReceiptAndRetainsTimeline() throws {
        let store = try ClipStore(root: root.appendingPathComponent("phone"))
        let (inbox, clip) = try fixture(store); _ = try store.receive(inbox, clip: clip)
        XCTAssertThrowsError(try store.commitCloudReceipt(cloud(clip, bytes: clip.byteCount+1), clip: clip, purge: true, uploadActive: false))
        XCTAssertTrue(store.hasLocalAudio(clip.id))
        try store.commitCloudReceipt(cloud(clip), clip: clip, purge: false, uploadActive: false)
        XCTAssertTrue(store.hasLocalAudio(clip.id))
        try store.commitCloudReceipt(cloud(clip), clip: clip, purge: true, uploadActive: true)
        XCTAssertTrue(store.hasLocalAudio(clip.id))
        XCTAssertTrue(store.retainAudio(clip.id)); XCTAssertTrue(store.retainAudio(clip.id))
        store.releaseAudio(clip.id)
        try store.commitCloudReceipt(cloud(clip), clip: clip, purge: true, uploadActive: false)
        XCTAssertTrue(store.hasLocalAudio(clip.id))
        store.releaseAudio(clip.id)
        try store.commitCloudReceipt(cloud(clip), clip: clip, purge: true, uploadActive: false)
        XCTAssertFalse(store.hasLocalAudio(clip.id))
        XCTAssertEqual(try store.clips().count, 1)
        XCTAssertTrue(store.cloudReceipt(clip.id)?.matches(clip) == true)
        XCTAssertFalse(store.retainAudio(clip.id))
    }
    func testCloudJournalFailureCannotEvictAudio() throws {
        let store = try ClipStore(root: root.appendingPathComponent("phone"))
        let (inbox, clip) = try fixture(store); _ = try store.receive(inbox, clip: clip)
        let blocker = store.root.appendingPathComponent(clip.id.uuidString + ".cloud.json")
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.commitCloudReceipt(cloud(clip), clip: clip, purge: true, uploadActive: false))
        XCTAssertTrue(store.hasLocalAudio(clip.id))
    }
    func testDriveProofRequiresServerHashSizeIDAndNotTrashed() throws {
        let hash = String(repeating: "a", count: 64)
        let item = UploadArtifact(fileID: "a", localName: "a.m4a", mimeType: "audio/mp4", byteCount: 12, sha256: hash)
        XCTAssertTrue(DriveFile(id: "a", size: "12", sha256Checksum: hash, trashed: false).verifies(item))
        XCTAssertFalse(DriveFile(id: "a", size: "12", sha256Checksum: nil, trashed: false).verifies(item))
        XCTAssertFalse(DriveFile(id: "a", size: "13", sha256Checksum: hash, trashed: false).verifies(item))
        XCTAssertFalse(DriveFile(id: "b", size: "12", sha256Checksum: hash, trashed: false).verifies(item))
        XCTAssertFalse(DriveFile(id: "a", size: "12", sha256Checksum: hash, trashed: true).verifies(item))
        XCTAssertFalse(DriveFile(id: "a", size: "12", sha256Checksum: String(repeating: "b", count: 64), trashed: false).verifies(item))
    }
}
