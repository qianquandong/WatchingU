import Foundation
import CryptoKit

/// Optional context lives beside audio, so a late mark never changes an audio checksum.
struct RecordingContextSettings: Codable, Equatable {
    var locationEnabled = false
    var healthEnabled = false
}

struct RecordedCoordinate: Codable, Equatable {
    let latitude: Double
    let longitude: Double
    let horizontalAccuracy: Double
    var isValid: Bool {
        latitude.isFinite && longitude.isFinite && horizontalAccuracy.isFinite &&
        (-90...90).contains(latitude) && (-180...180).contains(longitude) &&
        horizontalAccuracy >= 0 && horizontalAccuracy <= 10_000
    }
}

struct RecordingContextPacket: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case mark, location }
    let id: UUID
    let sessionID: UUID
    let recordedAt: Date
    let kind: Kind
    let label: String?
    let coordinate: RecordedCoordinate?
    var clipID: UUID? = nil
    var clipOffset: Double? = nil
    var isValid: Bool {
        guard recordedAt.timeIntervalSince1970.isFinite else { return false }
        switch kind {
        case .mark:
            let positionValid = (clipID == nil && clipOffset == nil) ||
                (clipID != nil && clipOffset.map { $0.isFinite && $0 >= 0 && $0 < 180 } == true)
            return positionValid && coordinate == nil && label.map { !$0.isEmpty && $0.utf8.count <= 256 } == true
        case .location: return label == nil && coordinate?.isValid == true && clipID == nil && clipOffset == nil
        }
    }
}

struct RecordingMark: Codable, Equatable, Identifiable {
    let id: UUID
    let sessionID: UUID
    let recordedAt: Date
    let label: String
    let clipID: UUID?
    let clipOffset: Double?
}

struct ContextReceipt: Codable, Equatable {
    let packetID: UUID
    let byteCount: UInt64
    let sha256: String
    func matches(id: UUID, bytes: UInt64, digest: String) -> Bool {
        packetID == id && byteCount == bytes && sha256 == digest
    }
}

struct WatchTransferBatch {
    private(set) var cutoff: Date?
    private(set) var manual = false
    private(set) var lastStarted = Date.distantPast
    mutating func prepare(at now: Date, force: Bool, manualOverride: Bool,
                          batteryLevel: Float, charging: Bool) -> Bool {
        if manualOverride { cutoff = now; manual = true; lastStarted = now }
        let lowBattery = batteryLevel >= 0 && batteryLevel < 0.2 && !charging
        guard manual || !lowBattery else { return false }
        if cutoff == nil {
            guard force || now.timeIntervalSince(lastStarted) >= 15 * 60 else { return false }
            cutoff = now; lastStarted = now
        }
        return true
    }
    mutating func finishIfDrained(audioPending: Bool, contextPending: Bool) {
        if !audioPending && !contextPending { cutoff = nil; manual = false }
    }
}

struct HealthContextSnapshot: Codable, Equatable {
    let clipID: UUID
    let intervalStart: Date
    let intervalEnd: Date
    let capturedAt: Date
    let averageHeartRate: Double?
    /// HealthKit's HRV SDNN, in milliseconds; this is not an emotion/stress diagnosis.
    let averageHRVSDNN: Double?
    let stepCount: Double?
    let activeEnergyKilocalories: Double?
    let sleepMinutes: Double?
}

enum HealthContextMath {
    /// Union overlapping samples (including duplicate device sources), clipped to the recording.
    static func sleepMinutes(intervals: [(Date, Date)], from start: Date, to end: Date) -> Double {
        guard end > start else { return 0 }
        let ranges = intervals.map { (max(start, $0.0), min(end, $0.1)) }
            .filter { $0.1 > $0.0 }.sorted { $0.0 < $1.0 }
        var total: TimeInterval = 0
        var current: (Date, Date)?
        for range in ranges {
            if let prior = current, range.0 <= prior.1 { current = (prior.0, max(prior.1, range.1)) }
            else {
                if let prior = current { total += prior.1.timeIntervalSince(prior.0) }
                current = range
            }
        }
        if let prior = current { total += prior.1.timeIntervalSince(prior.0) }
        return total / 60
    }
}

/// Bounded per-event files and independent receipts survive audio ACK cleanup and app relaunches.
final class RecordingContextStore {
    let root: URL
    private static let lock = NSRecursiveLock()
    private let encoder: JSONEncoder = {
        let value = JSONEncoder(); value.outputFormatting = [.sortedKeys]; return value
    }()
    private let decoder = JSONDecoder()
    private struct SendState: Codable { let attempts: Int; let retryAfter: Date }
    private struct DeletedInterval: Codable {
        let clipID: UUID
        let sessionID: UUID?
        let start: Date?
        let end: Date?
        func contains(_ packet: RecordingContextPacket) -> Bool {
            if let mapped = packet.clipID { return mapped == clipID }
            guard let sessionID = sessionID, let start = start, let end = end else { return false }
            return packet.sessionID == sessionID && packet.recordedAt >= start && packet.recordedAt < end
        }
    }
    init(root: URL) throws {
        self.root = root.appendingPathComponent("RecordingContext", isDirectory: true)
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }
    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        Self.lock.lock(); defer { Self.lock.unlock() }; return try body()
    }
    private func url(_ id: UUID, suffix: String) -> URL { root.appendingPathComponent(id.uuidString + suffix) }
    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        #if os(iOS) || os(watchOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
        let file = try FileHandle(forWritingTo: url); defer { try? file.close() }; try file.synchronize()
    }
    private func proof(_ data: Data) -> (UInt64, String) {
        (UInt64(data.count), SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }
    private func deletedIntervals() throws -> [DeletedInterval] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".contextdeleted.json") }
            .map { try decoder.decode(DeletedInterval.self, from: Data(contentsOf: $0)) }
    }
    private func isDeleted(_ clipID: UUID) -> Bool {
        FileManager.default.fileExists(atPath: url(clipID, suffix: ".contextdeleted.json").path) ||
            FileManager.default.fileExists(atPath: root.deletingLastPathComponent()
                .appendingPathComponent(clipID.uuidString + ".deleted.json").path)
    }
    func settings() throws -> RecordingContextSettings {
        try locked {
            let path = root.appendingPathComponent("settings.json")
            guard FileManager.default.fileExists(atPath: path.path) else { return RecordingContextSettings() }
            return try decoder.decode(RecordingContextSettings.self, from: Data(contentsOf: path))
        }
    }
    func saveSettings(_ value: RecordingContextSettings) throws {
        try locked { try write(encoder.encode(value), to: root.appendingPathComponent("settings.json")) }
    }
    @discardableResult
    func addMark(sessionID: UUID, at date: Date, label: String = "重要时刻", clipID: UUID? = nil, clipOffset: Double? = nil) throws -> RecordingContextPacket {
        let value = RecordingContextPacket(id: UUID(), sessionID: sessionID, recordedAt: date,
                                           kind: .mark, label: label, coordinate: nil, clipID: clipID, clipOffset: clipOffset)
        try save(value); return value
    }
    func addLocation(sessionID: UUID, at date: Date, coordinate: RecordedCoordinate) throws {
        try save(RecordingContextPacket(id: UUID(), sessionID: sessionID, recordedAt: date,
                                         kind: .location, label: nil, coordinate: coordinate))
    }
    private func save(_ value: RecordingContextPacket) throws {
        try locked {
            guard value.isValid else { throw ArchiveError.invalidMetadata }
            try write(encoder.encode(value), to: url(value.id, suffix: ".context.json"))
        }
    }
    func packets() throws -> [RecordingContextPacket] {
        try locked {
            try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasSuffix(".context.json") }
                .map { path in
                    let value = try decoder.decode(RecordingContextPacket.self, from: Data(contentsOf: path))
                    guard value.isValid else { throw ArchiveError.invalidMetadata }; return value
                }.sorted { $0.recordedAt < $1.recordedAt }
        }
    }
    func pending() throws -> [(URL, RecordingContextPacket, UInt64, String)] {
        try locked {
            try packets().compactMap { packet in
                let path = url(packet.id, suffix: ".context.json")
                let pair = proof(try Data(contentsOf: path))
                if let data = try? Data(contentsOf: url(packet.id, suffix: ".contextack.json")),
                   let receipt = try? decoder.decode(ContextReceipt.self, from: data),
                   receipt.matches(id: packet.id, bytes: pair.0, digest: pair.1) { return nil }
                return (path, packet, pair.0, pair.1)
            }
        }
    }
    func mayEnqueue(_ id: UUID, at date: Date) -> Bool {
        locked {
            guard let data = try? Data(contentsOf: url(id, suffix: ".contextretry.json")),
                  let state = try? decoder.decode(SendState.self, from: data) else { return true }
            return date >= state.retryAfter
        }
    }
    func noteEnqueued(_ id: UUID, at date: Date) throws {
        try locked {
            let path = url(id, suffix: ".contextretry.json")
            let prior = (try? Data(contentsOf: path)).flatMap { try? decoder.decode(SendState.self, from: $0) }
            let attempts = min(16, (prior?.attempts ?? 0) + 1)
            let delay = min(3600, 60 * pow(2, Double(attempts)))
            try write(encoder.encode(SendState(attempts: attempts, retryAfter: date.addingTimeInterval(delay))), to: path)
        }
    }
    /// The WatchConnectivity temporary inbox must be copied before its callback returns.
    func receive(_ inbox: URL, id: UUID, expectedBytes: UInt64, expectedHash: String) throws -> ContextReceipt {
        try locked {
            let size = try inbox.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= 16 * 1024, UInt64(size) == expectedBytes else { throw ArchiveError.invalidMetadata }
            let data = try Data(contentsOf: inbox)
            guard !data.isEmpty, data.count <= 16 * 1024 else { throw ArchiveError.invalidMetadata }
            let pair = proof(data)
            guard pair.0 == expectedBytes, pair.1 == expectedHash else { throw ArchiveError.checksumMismatch }
            let value = try decoder.decode(RecordingContextPacket.self, from: data)
            guard value.id == id, value.isValid, value.recordedAt <= Date().addingTimeInterval(60) else { throw ArchiveError.invalidMetadata }
            // User-deleted marks must not reappear when an old Watch transfer is retried.
            if value.kind == .mark {
                if value.clipID.map({ isDeleted($0) }) == true {
                    return ContextReceipt(packetID: id, byteCount: pair.0, sha256: pair.1)
                }
                if try deletedIntervals().contains(where: { $0.contains(value) }) {
                    return ContextReceipt(packetID: id, byteCount: pair.0, sha256: pair.1)
                }
            }
            let destination = url(id, suffix: ".context.json")
            if FileManager.default.fileExists(atPath: destination.path) {
                let prior = try decoder.decode(RecordingContextPacket.self, from: Data(contentsOf: destination))
                guard prior == value else { throw ArchiveError.conflict }
            }
            try write(data, to: destination)
            return ContextReceipt(packetID: id, byteCount: pair.0, sha256: pair.1)
        }
    }
    func acknowledge(_ receipt: ContextReceipt) throws {
        try locked {
            let path = url(receipt.packetID, suffix: ".context.json")
            guard FileManager.default.fileExists(atPath: path.path) else { return }
            let pair = proof(try Data(contentsOf: path))
            guard receipt.matches(id: receipt.packetID, bytes: pair.0, digest: pair.1) else { throw ArchiveError.checksumMismatch }
            try write(encoder.encode(receipt), to: url(receipt.packetID, suffix: ".contextack.json"))
            try? FileManager.default.removeItem(at: url(receipt.packetID, suffix: ".contextretry.json"))
            #if os(watchOS)
            // The phone now owns a durable copy. Bound Watch storage and avoid retaining
            // old locations/marks on the wrist after a user deletes their phone copy.
            try FileManager.default.removeItem(at: path)
            try? FileManager.default.removeItem(at: url(receipt.packetID, suffix: ".markposition.json"))
            try? FileManager.default.removeItem(at: url(receipt.packetID, suffix: ".contextack.json"))
            #endif
        }
    }
    /// Bind only to a clip from the same recording session that actually contains the mark.
    /// A mark at an exact segment boundary belongs to the following segment, never both.
    func resolveMarks(clips: [Clip]) throws {
        try locked {
            let eligible = clips.filter { !isDeleted($0.id) }
            for packet in try packets() where packet.kind == .mark {
                guard let clip = eligible.first(where: {
                    guard $0.sessionID == packet.sessionID else { return false }
                    if let mapped = packet.clipID, let offset = packet.clipOffset {
                        return mapped == $0.id && offset >= 0 && offset < $0.duration
                    }
                    return packet.recordedAt >= $0.startedAt && packet.recordedAt < $0.startedAt.addingTimeInterval($0.duration)
                }) else { continue }
                let value = RecordingMark(id: packet.id, sessionID: packet.sessionID, recordedAt: packet.recordedAt,
                                          label: packet.label!, clipID: clip.id,
                                          clipOffset: packet.clipOffset ?? packet.recordedAt.timeIntervalSince(clip.startedAt))
                let path = url(packet.id, suffix: ".markposition.json")
                if let data = try? Data(contentsOf: path), let prior = try? decoder.decode(RecordingMark.self, from: data), prior == value { continue }
                try write(encoder.encode(value), to: path)
            }
        }
    }
    func marks() throws -> [RecordingMark] {
        try locked {
            try packets().filter { $0.kind == .mark }.compactMap { packet -> RecordingMark? in
                if packet.clipID.map({ isDeleted($0) }) == true { return nil }
                if let data = try? Data(contentsOf: url(packet.id, suffix: ".markposition.json")),
                   let value = try? decoder.decode(RecordingMark.self, from: data), value.id == packet.id {
                    return value.clipID.map({ isDeleted($0) }) == true ? nil : value
                }
                return RecordingMark(id: packet.id, sessionID: packet.sessionID, recordedAt: packet.recordedAt,
                                     label: packet.label!, clipID: nil, clipOffset: nil)
            }
        }
    }
    func location(for clip: Clip) throws -> RecordingContextPacket? {
        try locked {
            guard !isDeleted(clip.id) else { return nil }
            return try packets().filter {
                $0.kind == .location && $0.sessionID == clip.sessionID &&
                $0.recordedAt <= clip.startedAt.addingTimeInterval(clip.duration) &&
                abs($0.recordedAt.timeIntervalSince(clip.startedAt)) <= 30 * 60
            }.min { abs($0.recordedAt.timeIntervalSince(clip.startedAt)) < abs($1.recordedAt.timeIntervalSince(clip.startedAt)) }
        }
    }
    func saveHealth(_ value: HealthContextSnapshot) throws {
        try locked {
            guard !isDeleted(value.clipID) else { return }
            try write(encoder.encode(value), to: url(value.clipID, suffix: ".health.json"))
        }
    }
    func health(for clipID: UUID) throws -> HealthContextSnapshot? {
        try locked {
            guard !isDeleted(clipID) else { return nil }
            let path = url(clipID, suffix: ".health.json")
            guard FileManager.default.fileExists(atPath: path.path) else { return nil }
            return try decoder.decode(HealthContextSnapshot.self, from: Data(contentsOf: path))
        }
    }
    func deleteContext(for clip: Clip) throws {
        try locked {
            guard clip.isValid else { throw ArchiveError.invalidMetadata }
            let interval = DeletedInterval(clipID: clip.id, sessionID: clip.sessionID, start: clip.startedAt,
                end: clip.startedAt.addingTimeInterval(clip.duration))
            // Write the small, non-content tombstone before removing context files.
            try write(encoder.encode(interval), to: url(clip.id, suffix: ".contextdeleted.json"))
            try deleteContext(for: clip.id)
        }
    }
    /// Recovery uses the authoritative audio tombstone even after the library row is gone.
    /// An ID alone never guesses the time range of an old, unresolved mark.
    func deleteContext(for clipID: UUID) throws {
        try locked {
            let tombstone = url(clipID, suffix: ".contextdeleted.json")
            let interval: DeletedInterval
            if FileManager.default.fileExists(atPath: tombstone.path) {
                interval = try decoder.decode(DeletedInterval.self, from: Data(contentsOf: tombstone))
                guard interval.clipID == clipID else { throw ArchiveError.invalidMetadata }
            } else {
                interval = DeletedInterval(clipID: clipID, sessionID: nil, start: nil, end: nil)
                try write(encoder.encode(interval), to: tombstone)
            }
            // Clear health first, even if an unrelated malformed packet needs a later retry.
            let health = url(clipID, suffix: ".health.json")
            if FileManager.default.fileExists(atPath: health.path) { try FileManager.default.removeItem(at: health) }
            var markIDs = Set<UUID>()
            for path in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                where path.lastPathComponent.hasSuffix(".markposition.json") {
                let value = try decoder.decode(RecordingMark.self, from: Data(contentsOf: path))
                if value.clipID == clipID { markIDs.insert(value.id) }
            }
            for packet in try packets() where packet.kind == .mark && interval.contains(packet) {
                markIDs.insert(packet.id)
            }
            for id in markIDs {
                for suffix in [".context.json", ".markposition.json", ".contextack.json", ".contextretry.json"] {
                    let path = url(id, suffix: suffix)
                    if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
                }
            }
            // Location samples are shared by neighbouring clips. The tombstone removes this
            // clip's association without erasing a location still used by another recording.
        }
    }
}

extension Notification.Name {
    static let recordingContextChanged = Notification.Name("daytape.context.changed")
    static let recordingContextSettingsChanged = Notification.Name("daytape.context.settings.changed")
}
