import Foundation
import CryptoKit
import AVFoundation
#if SWIFT_PACKAGE
import RecorderRules
#endif

/// Both targets use the same on-disk format. All mutations are serialized by this lock.
final class ClipStore {
    let root: URL
    private let lock = NSRecursiveLock()
    private let fm = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var cachedIndex: [UUID:Clip]?
    private var cachedDeletedReceipts: [UUID: Receipt]?
    private var pins: [UUID: Int] = [:]
    func retainAudio(_ id: UUID) -> Bool {
        locked {
            guard (try? deletedClipIDs().contains(id)) == false, fm.fileExists(atPath: audioURL(id).path) else { return false }
            pins[id, default: 0] += 1; return true
        }
    }
    func releaseAudio(_ id: UUID) {
        locked { pins[id] = max(0, (pins[id] ?? 0) - 1) }
        NotificationCenter.default.post(name: .archiveChanged, object: nil)
    }
    private(set) var recoveryMessage: String?

    init(root: URL? = nil) throws {
        let manager = FileManager.default
        let base: URL
        if let root = root { base = root }
        else {
            base = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                   appropriateFor: nil, create: true).appendingPathComponent("DayTape", isDirectory: true)
        }
        self.root = base
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        try protect(base)
    }
    func locked<T>(_ block: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }; return try block()
    }
    func audioURL(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString + ".m4a") }
    func partURL(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString + ".part.m4a") }
    private func manifestURL(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString + ".clip.json") }
    private func receiptURL(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString + ".ack.json") }
    private func draftURL(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString + ".draft.json") }
    private func cloudURL(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString + ".cloud.json") }
    func hasLocalAudio(_ id: UUID) -> Bool {
        locked { (try? deletedClipIDs().contains(id)) == false && fm.fileExists(atPath: audioURL(id).path) }
    }
    func cloudReceipt(_ id: UUID) -> CloudReceipt? {
        locked {
            guard (try? deletedClipIDs().contains(id)) == false else { return nil }
            guard let data = try? Data(contentsOf: cloudURL(id)) else { return nil }
            return try? decoder.decode(CloudReceipt.self, from: data)
        }
    }
    /// Both audio and its JSON sidecar must already be verified against Drive's server checksums.
    /// Keep the clip manifest so the timeline and Drive link remain available after local eviction.
    func commitCloudReceipt(_ receipt: CloudReceipt, clip: Clip, purge: Bool, uploadActive: Bool) throws {
        try locked {
            guard !(try deletedClipIDs().contains(clip.id)) else { throw CloudArchiveError.cancelled }
            guard receipt.matches(clip) else { throw CloudArchiveError.remoteMismatch }
            try save(receipt, at: cloudURL(clip.id))
            let persisted = cloudReceipt(clip.id)?.matches(clip) == true
            let processingHeld = fm.fileExists(atPath: root.appendingPathComponent(clip.id.uuidString + ".processing-hold").path)
            if rr_can_purge_cloud_copy(1, persisted ? 1 : 0, uploadActive ? 1 : 0,
                                      purge && !processingHeld && (pins[clip.id] ?? 0) == 0 ? 0 : 1) != 0 {
                if fm.fileExists(atPath: audioURL(clip.id).path) { try fm.removeItem(at: audioURL(clip.id)) }
            }
        }
    }

    /// Explicit user deletion never touches Drive. A minimal tombstone prevents a late
    /// already-acknowledged Watch retransmission from restoring a deleted recording.
    func deleteByUser(_ clip: Clip) throws {
        defer { NotificationCenter.default.post(name: .archiveChanged, object: nil) }
        try locked {
            guard (pins[clip.id] ?? 0) == 0 else { throw ArchiveError.conflict }
            // Even if protection/synchronization or later removal fails, the next read must honor
            // any tombstone that reached disk before the error.
            defer { cachedDeletedReceipts = nil; cachedIndex = nil }
            try save(Receipt(clip: clip), at: root.appendingPathComponent(clip.id.uuidString + ".deleted.json"))
            cachedIndex?.removeValue(forKey: clip.id)
            cachedDeletedReceipts = nil
            try purgeDeletedAudio()
        }
    }

    /// Authoritative deletion intents. The small receipts are decoded once per store lifetime,
    /// and invalidated only when this store writes another tombstone.
    func deletedClipIDs() throws -> Set<UUID> { try locked { Set(try deletedReceipts().keys) } }
    private func deletedReceipts() throws -> [UUID: Receipt] {
        if let cachedDeletedReceipts { return cachedDeletedReceipts }
        var result: [UUID: Receipt] = [:]
        for url in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            where url.lastPathComponent.hasSuffix(".deleted.json") {
            let name = String(url.lastPathComponent.dropLast(".deleted.json".count))
            let receipt = try decoder.decode(Receipt.self, from: Data(contentsOf: url))
            guard let id = UUID(uuidString: name), receipt.clipID == id,
                  receipt.byteCount > 0, receipt.byteCount < 16 * 1024 * 1024,
                  receipt.sha256.count == 64,
                  receipt.sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
                  receipt.savedAt.timeIntervalSince1970.isFinite else { throw ArchiveError.invalidMetadata }
            result[id] = receipt
        }
        cachedDeletedReceipts = result; return result
    }
    func pendingDeletedAudioIDs(only ids: Set<UUID>? = nil) throws -> Set<UUID> {
        try locked {
            Set(try deletedReceipts().keys.filter { id in
                (ids == nil || ids?.contains(id) == true) && deletionURLs(id).contains { fm.fileExists(atPath: $0.path) }
            })
        }
    }
    /// Retries only local files for validated tombstones; the tombstone and Drive copy remain.
    func purgeDeletedAudio(only ids: Set<UUID>? = nil) throws {
        try locked {
            var firstError: Error?
            for (id, receipt) in try deletedReceipts() {
                if let ids, !ids.contains(id) { continue }
                do {
                    guard (pins[id] ?? 0) == 0 else { throw ArchiveError.conflict }
                    if fm.fileExists(atPath: manifestURL(id).path) {
                        let clip = try decoder.decode(Clip.self, from: Data(contentsOf: manifestURL(id)))
                        guard receipt.matches(clip) else { throw ArchiveError.conflict }
                    }
                    for url in deletionURLs(id) where fm.fileExists(atPath: url.path) {
                        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw ArchiveError.invalidMetadata }
                        try fm.removeItem(at: url)
                    }
                    cachedIndex?.removeValue(forKey: id)
                } catch { if firstError == nil { firstError = error } }
            }
            if let firstError { throw firstError }
        }
    }
    private func deletionURLs(_ id: UUID) -> [URL] {
        [audioURL(id), cloudURL(id), root.appendingPathComponent(id.uuidString + ".processing-hold"), manifestURL(id)]
    }

    private func protect(_ url: URL) throws {
        #if os(iOS) || os(watchOS)
        try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                             ofItemAtPath: url.path)
        #endif
    }
    private func flush(_ url: URL) throws {
        let file = try FileHandle(forWritingTo: url); defer { try? file.close() }
        try file.synchronize()
    }
    private func save<T: Encodable>(_ value: T, at url: URL) throws {
        try encoder.encode(value).write(to: url, options: .atomic)
        try protect(url)
        try flush(url)
    }
    func hash(_ url: URL) throws -> (UInt64, String) {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var hasher = SHA256(); var bytes: UInt64 = 0
        while let data = try file.read(upToCount: 256 * 1024), !data.isEmpty {
            hasher.update(data: data); bytes += UInt64(data.count)
        }
        return (bytes, hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }
    func clips() throws -> [Clip] {
        try locked {
            let deleted = try deletedClipIDs()
            if let index = cachedIndex { return index.values.filter { !deleted.contains($0.id) }.sorted { $0.startedAt < $1.startedAt } }
            let result = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasSuffix(".clip.json") }
                .filter { url in
                    guard let id = UUID(uuidString: String(url.lastPathComponent.dropLast(".clip.json".count))) else { return true }
                    return !deleted.contains(id)
                }
                .map {
                    let clip = try decoder.decode(Clip.self, from: Data(contentsOf: $0))
                    guard clip.isValid else { throw ArchiveError.invalidMetadata }
                    return clip
                }
                .sorted { $0.startedAt < $1.startedAt }
            cachedIndex = Dictionary(uniqueKeysWithValues: result.map { ($0.id,$0) })
            return result
        }
    }
    func isConfirmed(_ clip: Clip) -> Bool {
        locked {
            guard let data = try? Data(contentsOf: receiptURL(clip.id)),
                  let receipt = try? decoder.decode(Receipt.self, from: data) else { return false }
            return receipt.matches(clip)
        }
    }
    func pending() throws -> [Clip] { try clips().filter { !isConfirmed($0) } }
    func update(_ clip: Clip) throws { try locked { try save(clip, at: manifestURL(clip.id)); cachedIndex?[clip.id] = clip } }
    func writeDraft(_ draft: CaptureDraft) throws { try locked { try save(draft, at: draftURL(draft.id)) } }
    func ensureBudget() throws {
        try locked {
            let attributes = try fm.attributesOfFileSystem(forPath: root.path)
            guard let free = attributes[.systemFreeSize] as? NSNumber else { throw ArchiveError.storageBudget }
            let pendingBytes = try pending().reduce(UInt64(0)) { $0 + $1.byteCount }
            guard rr_budget_allows(free.uint64Value, pendingBytes, 2 * 1024 * 1024,
                                   100 * 1024 * 1024, 1024 * 1024 * 1024) != 0 else {
                throw ArchiveError.storageBudget
            }
        }
    }
    func seal(_ draft: CaptureDraft, duration: Double) throws -> Clip {
        try locked {
            let source = partURL(draft.id), destination = audioURL(draft.id)
            // The encoder must already have been released before calling seal.
            try protect(source); try flush(source)
            let readable = try AVAudioFile(forReading: source)
            guard readable.length > 0 else { throw ArchiveError.encoding }
            let (bytes, digest) = try hash(source)
            let clip = Clip(id: draft.id, sessionID: draft.sessionID, startedAt: draft.startedAt,
                            duration: duration, byteCount: bytes, sha256: digest)
            guard clip.isValid else { throw ArchiveError.invalidMetadata }
            if fm.fileExists(atPath: destination.path) {
                let current = try hash(destination)
                guard current.0 == bytes && current.1 == digest else { throw ArchiveError.conflict }
            } else { try fm.moveItem(at: source, to: destination) }
            try save(clip, at: manifestURL(clip.id))
            cachedIndex?[clip.id] = clip
            #if os(watchOS)
            try appendDayLedger(clip)
            #endif
            try? fm.removeItem(at: draftURL(draft.id))
            return clip
        }
    }
    /// Called synchronously inside didReceive file: the inbox URL expires on return.
    func receive(_ inbox: URL, clip: Clip) throws -> Receipt {
        try locked {
            guard clip.isValid else { throw ArchiveError.invalidMetadata }
            let (count, digest) = try hash(inbox)
            guard count == clip.byteCount && digest == clip.sha256 else { throw ArchiveError.checksumMismatch }
            let tombstone = root.appendingPathComponent(clip.id.uuidString + ".deleted.json")
            if fm.fileExists(atPath: tombstone.path) {
                let receipt = try decoder.decode(Receipt.self, from: Data(contentsOf: tombstone))
                guard receipt.matches(clip) else { throw ArchiveError.conflict }
                return receipt
            }
            let destination = audioURL(clip.id)
            if fm.fileExists(atPath: destination.path) {
                let current = try hash(destination)
                guard current.0 == clip.byteCount && current.1 == clip.sha256 else { throw ArchiveError.conflict }
            } else {
                let stage = root.appendingPathComponent(UUID().uuidString + ".incoming")
                defer { try? fm.removeItem(at: stage) }
                try fm.copyItem(at: inbox, to: stage)
                try protect(stage); try flush(stage)
                try fm.moveItem(at: stage, to: destination)
            }
            var canonical = clip; canonical.attempts = 0; canonical.retryAfter = .distantPast
            try save(canonical, at: manifestURL(clip.id))
            cachedIndex?[clip.id] = canonical
            // Closure integrity is part of the shared storage protocol on every platform.
            try checkIncomingClipAgainstClosure(canonical)
            // No acknowledgement is emitted if either audio or manifest persistence failed.
            return Receipt(clip: canonical)
        }
    }
    func acknowledge(_ receipt: Receipt) throws {
        try locked {
            let url = manifestURL(receipt.clipID)
            guard fm.fileExists(atPath: url.path) else { return } // late duplicate acknowledgement
            let clip = try decoder.decode(Clip.self, from: Data(contentsOf: url))
            guard receipt.matches(clip) else { throw ArchiveError.checksumMismatch }
            // Persist a matching receipt first. A crash during cleanup cannot make this clip pending again.
            try save(receipt, at: receiptURL(clip.id))
            try cleanupConfirmed(clip)
        }
    }
    private func cleanupConfirmed(_ clip: Clip) throws {
        guard isConfirmed(clip) else { return }
        if fm.fileExists(atPath: audioURL(clip.id).path) { try fm.removeItem(at: audioURL(clip.id)) }
        if fm.fileExists(atPath: manifestURL(clip.id).path) { try fm.removeItem(at: manifestURL(clip.id)) }
        cachedIndex?.removeValue(forKey: clip.id)
        // The journal is needed during cleanup only; avoid an unbounded accumulation of ACK files.
        try? fm.removeItem(at: receiptURL(clip.id))
    }
    func recover() throws {
        try locked {
            cachedIndex = nil
            defer { cachedIndex = nil }
            #if os(watchOS)
            for clip in try clips() where isConfirmed(clip) { try cleanupConfirmed(clip) }
            #endif
            let drafts = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasSuffix(".draft.json") }
            var recovered = 0, held = 0
            for url in drafts {
                do {
                    let draft = try decoder.decode(CaptureDraft.self, from: Data(contentsOf: url))
                    let final = audioURL(draft.id)
                    if fm.fileExists(atPath: final.path) {
                        if !fm.fileExists(atPath: manifestURL(draft.id).path) {
                            let audio = try AVAudioFile(forReading: final)
                            let pair = try hash(final)
                            let clip = Clip(id: draft.id, sessionID: draft.sessionID, startedAt: draft.startedAt,
                                            duration: Double(audio.length)/audio.fileFormat.sampleRate,
                                            byteCount: pair.0, sha256: pair.1)
                            guard clip.isValid else { throw ArchiveError.invalidMetadata }
                            try save(clip, at: manifestURL(clip.id))
                        }
                        try fm.removeItem(at: url); recovered += 1
                    } else {
                        let audio = try AVAudioFile(forReading: partURL(draft.id))
                        let duration = Double(audio.length)/audio.fileFormat.sampleRate
                        _ = try seal(draft, duration: duration); recovered += 1
                    }
                } catch { held += 1 } // Preserve every undecodable or incomplete recording for manual recovery.
            }
            if recovered + held > 0 {
                recoveryMessage = "上次录音未正常结束：恢复 \(recovered) 段，保留 \(held) 个未完成文件。请手动开始新录音。"
            }
            #if os(watchOS)
            // Repair the separate ledger before any clip ACK can remove the per-clip manifest.
            for clip in try clips() { try appendDayLedger(clip) }
            if held == 0 { try finishCaptureMarker() }
            #endif
        }
    }
    func log(_ kind: String, detail: String) {
        locked {
            let entry = ["date": ISO8601DateFormatter().string(from: Date()), "event": kind, "detail": detail]
            guard let data = try? JSONSerialization.data(withJSONObject: entry) else { return }
            let url = root.appendingPathComponent(UUID().uuidString + ".event.json")
            try? data.write(to: url, options: .atomic)
        }
    }
}
