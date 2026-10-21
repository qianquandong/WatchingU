import Foundation
import CryptoKit

/// This inventory survives Watch ACK cleanup. A closed day means all persisted segments
/// have been enumerated, not that audio coverage was uninterrupted.
struct DayClosure: Codable {
    let dayKey: String
    let dayStart: Date
    let cutoff: Date
    let closedAt: Date
    let timeZoneID: String
    let clips: [Clip]
    var revision: String { Self.digest(clips) }
    static func digest(_ clips: [Clip]) -> String {
        let lines = clips.sorted { $0.id.uuidString < $1.id.uuidString }.map {
            "\($0.id.uuidString)|\($0.sessionID.uuidString)|\($0.startedAt.timeIntervalSince1970)|\($0.duration)|\($0.byteCount)|\($0.sha256)"
        }.joined(separator: "\n")
        return SHA256.hash(data: Data(lines.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    var isValid: Bool {
        var policy = DailySchedule(); policy.timeZoneID = timeZoneID
        guard policy.isValid, !clips.isEmpty, clips.count <= 3000,
              Set(clips.map(\.id)).count == clips.count,
              dayStart == policy.dayStart(dayStart), dayKey == policy.dayKey(dayStart),
              cutoff > dayStart, cutoff < dayStart.addingTimeInterval(27 * 3600), closedAt >= cutoff,
              closedAt.timeIntervalSince1970.isFinite else { return false }
        return clips.allSatisfy {
            $0.isValid && $0.startedAt.timeIntervalSince1970.isFinite && policy.dayKey($0.startedAt) == dayKey &&
            $0.startedAt.addingTimeInterval($0.duration) <= cutoff
        }
    }
    func matches(_ actual: [Clip]) -> Bool {
        isValid && actual.count == clips.count && Self.digest(actual) == revision
    }
}

private struct CaptureMarker: Codable { let sessionID: UUID; let startedAt: Date }
private struct DayLedger: Codable {
    let dayStart: Date
    let cutoff: Date
    let timeZoneID: String
    var clips: [Clip]
}

extension ClipStore {
    private func dayFile(_ key: String, suffix: String) -> URL {
        root.appendingPathComponent("day-" + key + suffix)
    }
    private func writeDayValue<T: Encodable>(_ value: T, _ url: URL) throws {
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        #if os(iOS) || os(watchOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }; try handle.synchronize()
    }
    func dailySchedule() throws -> DailySchedule {
        try locked {
            let url = root.appendingPathComponent("daily-plan.json")
            guard FileManager.default.fileExists(atPath: url.path) else { return DailySchedule() }
            let result = try JSONDecoder().decode(DailySchedule.self, from: Data(contentsOf: url))
            guard result.isValid else { throw ArchiveError.invalidMetadata }; return result
        }
    }
    func saveDailySchedule(_ value: DailySchedule) throws {
        try locked {
            guard value.isValid else { throw ArchiveError.invalidMetadata }
            try writeDayValue(value, root.appendingPathComponent("daily-plan.json"))
        }
    }
    func beginCaptureMarker(sessionID: UUID, at date: Date) throws {
        try locked { try writeDayValue(CaptureMarker(sessionID: sessionID, startedAt: date), root.appendingPathComponent("capture-active.json")) }
    }
    func finishCaptureMarker() throws {
        try locked {
            let url = root.appendingPathComponent("capture-active.json")
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }
    func appendDayLedger(_ clip: Clip) throws {
        try locked {
            let policy = try dailySchedule(), key = policy.dayKey(clip.startedAt)
            let folder = root.appendingPathComponent("DayLedgers", isDirectory: true).appendingPathComponent(key, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(clip.id.uuidString + ".json")
            if FileManager.default.fileExists(atPath: url.path) {
                let prior = try JSONDecoder().decode(DayLedger.self, from: Data(contentsOf: url))
                guard DayClosure.digest(prior.clips) == DayClosure.digest([clip]) else { throw ArchiveError.conflict }
                return
            }
            if FileManager.default.fileExists(atPath: dayFile(key, suffix: ".seal.json").path) {
                try writeDayValue(["reason":"late-segment"], dayFile(key, suffix: ".blocked.json"))
            }
            let cutoff = policy.stopDeadline(for: clip.startedAt) ??
                policy.calendar.date(byAdding: .day, value: 1, to: policy.dayStart(clip.startedAt))!
            var canonical = clip; canonical.attempts = 0; canonical.retryAfter = .distantPast
            // One immutable small entry per segment: never rewrite the growing entire-day ledger.
            let entry = DayLedger(dayStart: policy.dayStart(clip.startedAt), cutoff: cutoff,
                                  timeZoneID: policy.timeZoneID, clips: [canonical])
            try writeDayValue(entry, url)
        }
    }
    /// Call only while no active encoder exists. Captures with unresolved drafts cannot close.
    func sealDueDays(now: Date = Date()) throws {
        try locked {
            guard !FileManager.default.fileExists(atPath: root.appendingPathComponent("capture-active.json").path) else { return }
            let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            let drafts = files.filter { $0.lastPathComponent.hasSuffix(".draft.json") }
            guard drafts.isEmpty else { return }
            let ledgerRoot = root.appendingPathComponent("DayLedgers", isDirectory: true)
            guard FileManager.default.fileExists(atPath: ledgerRoot.path) else { return }
            for folder in try FileManager.default.contentsOfDirectory(at: ledgerRoot, includingPropertiesForKeys: nil) {
                let key = folder.lastPathComponent, destination = dayFile(key, suffix: ".seal.json")
                if FileManager.default.fileExists(atPath: destination.path) { continue }
                let entries = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                    .filter { $0.pathExtension == "json" }
                    .map { try JSONDecoder().decode(DayLedger.self, from: Data(contentsOf: $0)) }
                guard let first = entries.first, let cutoff = entries.map(\.cutoff).max(), now >= cutoff else { continue }
                guard entries.allSatisfy({ $0.dayStart == first.dayStart && $0.timeZoneID == first.timeZoneID }) else { throw ArchiveError.conflict }
                let closure = DayClosure(dayKey: key, dayStart: first.dayStart, cutoff: cutoff,
                                         closedAt: now, timeZoneID: first.timeZoneID, clips: entries.flatMap(\.clips))
                guard closure.isValid else { throw ArchiveError.invalidMetadata }
                try writeDayValue(closure, destination)
            }
        }
    }
    func dayClosures() throws -> [(URL, DayClosure)] {
        try locked {
            try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasSuffix(".seal.json") }
                .map { url in
                    let value = try JSONDecoder().decode(DayClosure.self, from: Data(contentsOf: url))
                    guard value.isValid else { throw ArchiveError.invalidMetadata }; return (url, value)
                }
        }
    }
    func dayIsBlocked(_ key: String) -> Bool {
        locked { FileManager.default.fileExists(atPath: dayFile(key, suffix: ".blocked.json").path) }
    }
    func receiveDayClosure(_ inbox: URL, expectedHash: String, expectedBytes: UInt64) throws {
        try locked {
            let proof = try hash(inbox)
            guard proof.0 > 0, proof.0 <= 4 * 1024 * 1024, proof.0 == expectedBytes, proof.1 == expectedHash else { throw ArchiveError.checksumMismatch }
            let value = try JSONDecoder().decode(DayClosure.self, from: Data(contentsOf: inbox))
            guard value.isValid, value.closedAt <= Date().addingTimeInterval(60) else { throw ArchiveError.invalidMetadata }
            let url = dayFile(value.dayKey, suffix: ".seal.json")
            if FileManager.default.fileExists(atPath: url.path) {
                let previous = try JSONDecoder().decode(DayClosure.self, from: Data(contentsOf: url))
                if previous.revision != value.revision || previous.timeZoneID != value.timeZoneID {
                    try writeDayValue(["reason":"conflicting-day-closure"], dayFile(value.dayKey, suffix: ".blocked.json"))
                    throw ArchiveError.conflict
                }
            }
            try writeDayValue(value, url)
        }
    }
    func isDayConfirmed(_ closure: DayClosure) -> Bool {
        locked {
            let url = dayFile(closure.dayKey, suffix: ".dayack.json")
            guard let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode([String:String].self, from: data) else { return false }
            return value["revision"] == closure.revision
        }
    }
    func acknowledgeDay(_ key: String, revision: String) throws {
        try locked {
            guard let closure = try dayClosures().map(\.1).first(where: { $0.dayKey == key }), closure.revision == revision else { throw ArchiveError.checksumMismatch }
            try writeDayValue(["revision":revision], dayFile(key, suffix: ".dayack.json"))
        }
    }
    func completeDays(accountID: String, policy: DailySchedule) throws -> [DayClosure] {
        try locked {
            let allClips = try clips()
            return try dayClosures().map(\.1).filter { closure in
                guard closure.timeZoneID == policy.timeZoneID, !dayIsBlocked(closure.dayKey),
                      closure.matches(allClips.filter { policy.dayKey($0.startedAt) == closure.dayKey }) else { return false }
                return closure.clips.allSatisfy { clip in
                    guard let proof = cloudReceipt(clip.id) else { return false }
                    return proof.accountID == accountID && proof.matches(clip)
                }
            }.sorted { $0.dayStart < $1.dayStart }
        }
    }
    func checkIncomingClipAgainstClosure(_ clip: Clip) throws {
        try locked {
            let policy = try dailySchedule(), key = policy.dayKey(clip.startedAt)
            let url = dayFile(key, suffix: ".seal.json")
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            let closure = try JSONDecoder().decode(DayClosure.self, from: Data(contentsOf: url))
            if !closure.clips.contains(where: { $0.id == clip.id && DayClosure.digest([$0]) == DayClosure.digest([clip]) }) {
                try writeDayValue(["reason":"unexpected-received-clip"], dayFile(key, suffix: ".blocked.json"))
            }
        }
    }
}
