import Foundation

/// Main-actor-owned journal; tasks are written before URLSession starts, and never store OAuth tokens.
@MainActor
final class ArchiveJournal {
    let root: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    init(store: ClipStore) throws {
        root = store.root.appendingPathComponent("CloudArchive", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    private func write<T: Encodable>(_ value: T, url: URL) throws {
        try encoder.encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
        try handle.synchronize()
    }
    func settings() throws -> ArchiveSettings {
        let url = root.appendingPathComponent("settings.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return ArchiveSettings() }
        return try decoder.decode(ArchiveSettings.self, from: Data(contentsOf: url))
    }
    func save(_ settings: ArchiveSettings) throws { try write(settings, url: root.appendingPathComponent("settings.json")) }
    func jobs() throws -> [ArchiveJob] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".job.json") }
            .map { try decoder.decode(ArchiveJob.self, from: Data(contentsOf: $0)) }
    }
    func save(_ job: ArchiveJob) throws { try write(job, url: root.appendingPathComponent(job.clipID.uuidString + ".job.json")) }
    func payloadURL(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString + ".archive.json") }
    func makePayload(_ clip: Clip, store: ClipStore) throws -> (URL, UInt64, String) {
        let url = payloadURL(clip.id)
        if !FileManager.default.fileExists(atPath: url.path) {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(clip).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
            let handle = try FileHandle(forWritingTo: url); try handle.synchronize(); try handle.close()
        }
        let pair = try store.hash(url); return (url,pair.0,pair.1)
    }
    func discardPayload(_ id: UUID) { try? FileManager.default.removeItem(at: payloadURL(id)) }
    func hasNotified(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent("notice-" + id + ".json").path)
    }
    func markNotified(_ id: String) throws {
        try write(["date":Date()], url: root.appendingPathComponent("notice-" + id + ".json"))
    }
}
