import Foundation
import Security

struct IntelligenceSnapshot: Codable {
    var settings = IntelligenceSettings()
    var jobs: [TranscriptionJob] = []
    var reviews: [AIReview] = []
    var memories: [MemoryFact] = []
    var excludedClipIDs: [UUID]? = nil
    var transcriptionPaused: Bool? = nil
    var automaticReviewAttempts: [String: Date]? = nil
}

final class IntelligenceDisk {
    let root: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    init(root: URL) throws {
        self.root = root.appendingPathComponent("Intelligence", isDirectory: true)
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: documentsURL, withIntermediateDirectories: true)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                             ofItemAtPath: self.root.path)
        #endif
    }
    private var documentsURL: URL { root.appendingPathComponent("Transcripts", isDirectory: true) }
    private var stateURL: URL { root.appendingPathComponent("state.json") }
    func load() throws -> IntelligenceSnapshot {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return IntelligenceSnapshot() }
        return try decoder.decode(IntelligenceSnapshot.self, from: Data(contentsOf: stateURL))
    }
    func documents() throws -> [TranscriptDocument] {
        try FileManager.default.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { try decoder.decode(TranscriptDocument.self, from: Data(contentsOf: $0)) }
            .sorted { $0.startedAt < $1.startedAt }
    }
    func save(_ state: IntelligenceSnapshot) throws { try write(encoder.encode(state), to: stateURL) }
    func save(_ document: TranscriptDocument) throws {
        try write(encoder.encode(document), to: documentsURL.appendingPathComponent(document.clipID.uuidString + ".json"))
    }
    func deleteDocument(_ clipID: UUID) throws {
        let url = documentsURL.appendingPathComponent(clipID.uuidString + ".json")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    private var aiPartsURL: URL { root.appendingPathComponent("AIParts", isDirectory: true) }
    func chunk(fingerprint: String, stage: String, index: Int) throws -> AIWireReply? {
        let url = aiPartsURL.appendingPathComponent(fingerprint + "-" + stage + "-\(index).json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try decoder.decode(AIWireReply.self, from: Data(contentsOf: url))
    }
    func saveChunk(_ result: AIWireReply, fingerprint: String, stage: String, index: Int) throws {
        try FileManager.default.createDirectory(at: aiPartsURL, withIntermediateDirectories: true)
        try write(encoder.encode(result), to: aiPartsURL.appendingPathComponent(fingerprint + "-" + stage + "-\(index).json"))
    }
    func saveProgress(_ value: AIReviewProgress) throws {
        try FileManager.default.createDirectory(at: aiPartsURL, withIntermediateDirectories: true)
        try write(encoder.encode(value), to: aiPartsURL.appendingPathComponent("progress.json"))
    }
    func progress() throws -> AIReviewProgress? {
        let url = aiPartsURL.appendingPathComponent("progress.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try decoder.decode(AIReviewProgress.self, from: Data(contentsOf: url))
    }
    func registerAICache(fingerprint: String, clipIDs: [UUID]) throws {
        try FileManager.default.createDirectory(at: aiPartsURL, withIntermediateDirectories: true)
        try write(encoder.encode(clipIDs), to: aiPartsURL.appendingPathComponent(fingerprint + ".manifest.json"))
    }
    func deleteAICaches(containing clipID: UUID) throws {
        guard FileManager.default.fileExists(atPath: aiPartsURL.path) else { return }
        let files = try FileManager.default.contentsOfDirectory(at: aiPartsURL, includingPropertiesForKeys: nil)
        var removed: Set<String> = []
        for file in files where file.lastPathComponent.hasSuffix(".manifest.json") {
            let clips = try decoder.decode([UUID].self, from: Data(contentsOf: file))
            if clips.contains(clipID) {
                let prefix = String(file.lastPathComponent.dropLast(".manifest.json".count))
                for item in files where item.lastPathComponent.hasPrefix(prefix + "-") {
                    if FileManager.default.fileExists(atPath: item.path) { try FileManager.default.removeItem(at: item) }
                }
                // Keep the manifest until every derived part is gone, so crashes and errors
                // leave enough information for an idempotent retry.
                if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
                removed.insert(prefix)
            }
        }
        if let progress = try progress(), removed.contains(progress.fingerprint) {
            let url = aiPartsURL.appendingPathComponent("progress.json")
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }
    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                             ofItemAtPath: url.path)
        #endif
    }
}

enum IntelligenceKeychain {
    private static var service: String { (Bundle.main.bundleIdentifier ?? "DayTape") + ".intelligence" }
    private static func query(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    static func read(account: String = "compatible-api-key") throws -> String? {
        var request = query(account: account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            throw IntelligenceError.message("无法从钥匙串读取 API 密钥（\(status)）。")
        }
        return key
    }
    static func save(_ value: String, account: String = "compatible-api-key") throws {
        let query = query(account: account)
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw IntelligenceError.message("无法删除 API 密钥（\(status)）。")
            }
            return
        }
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw IntelligenceError.message("无法保存 API 密钥（\(added)）。") }
        } else if status != errSecSuccess { throw IntelligenceError.message("无法更新 API 密钥（\(status)）。") }
    }
}
