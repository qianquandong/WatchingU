import Foundation

struct TranscriptSegment: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var offset: Double
    var duration: Double
    var text: String
    var speakerLabel: String? = nil
    var speakerID: String? = nil
}

struct TranscriptDocument: Codable, Identifiable, Equatable {
    var id: UUID { clipID }
    var clipID: UUID
    var startedAt: Date
    var duration: Double
    var localeIdentifier: String
    var sourceSHA256: String
    var segments: [TranscriptSegment]
    var completedOffset: Double = 0
    var isComplete: Bool = false
    var updatedAt: Date = Date()
    var text: String { segments.map(\.text).joined(separator: " ") }
}

struct SourceCitation: Codable, Identifiable, Equatable, Hashable {
    var id: String { "\(clipID.uuidString):\(offset)" }
    var clipID: UUID
    var offset: Double
    var text: String
}

struct SearchHit: Codable, Identifiable, Equatable {
    var id: String { "\(clipID.uuidString):\(offset)" }
    var clipID: UUID
    var offset: Double
    var text: String
    var score: Double
    var startedAt: Date
}

struct AIReview: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case summary, highlights, reflection, answer
        var id: String { rawValue }
        var title: String {
            switch self {
            case .summary: return "每日总结"
            case .highlights: return "高光"
            case .reflection: return "每日回顾"
            case .answer: return "历史问答"
            }
        }
    }
    var id: UUID = UUID()
    var kind: Kind
    var day: Date
    var title: String
    var body: String
    var citations: [SourceCitation]
    var createdAt: Date = Date()
    var coverageNote: String? = nil
    var sourceFingerprint: String? = nil
    var inputClipIDs: [UUID]? = nil
}

struct MemoryFact: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var text: String
    var isActive: Bool = true
    var sourceCitations: [SourceCitation] = []
    var updatedAt: Date = Date()
    var inputClipIDs: [UUID]? = nil
}

struct TranscriptionJob: Codable, Identifiable, Equatable {
    enum State: String, Codable { case pending, running, paused, failed, completed }
    var id: UUID { clipID }
    var clipID: UUID
    var state: State = .pending
    var completedOffset: Double = 0
    var attempts: Int = 0
    var error: String? = nil
    var updatedAt: Date = Date()
}

struct IntelligenceSettings: Codable, Equatable {
    var localeIdentifier: String = "zh-CN"
    var automaticTranscription: Bool = false
    // Saving an endpoint or a key alone never permits a network request.
    var remoteAIEnabled: Bool = false
    var apiBaseURL: String = ""
    var model: String = ""
    var automaticReview: Bool = false

    init() {}
    enum CodingKeys: String, CodingKey {
        case localeIdentifier, automaticTranscription, remoteAIEnabled, apiBaseURL, model, automaticReview
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        localeIdentifier = try values.decodeIfPresent(String.self, forKey: .localeIdentifier) ?? "zh-CN"
        automaticTranscription = try values.decodeIfPresent(Bool.self, forKey: .automaticTranscription) ?? false
        remoteAIEnabled = try values.decodeIfPresent(Bool.self, forKey: .remoteAIEnabled) ?? false
        apiBaseURL = try values.decodeIfPresent(String.self, forKey: .apiBaseURL) ?? ""
        model = try values.decodeIfPresent(String.self, forKey: .model) ?? ""
        automaticReview = try values.decodeIfPresent(Bool.self, forKey: .automaticReview) ?? false
    }
}

struct AIReviewProgress: Codable, Identifiable, Equatable {
    enum Phase: String, Codable { case extracting, merging, finalizing, paused, failed, completed }
    var id: String { fingerprint + "|" + kind.rawValue }
    var fingerprint: String
    var day: Date
    var kind: AIReview.Kind
    var phase: Phase
    var completedBlocks: Int
    var totalBlocks: Int
    var pendingTranscripts: Int
    var message: String
    var updatedAt: Date = Date()
}

enum AIContextPlanner {
    /// Every source index occurs exactly once. An oversized indivisible item gets its own block;
    /// callers must process it or report an error rather than silently dropping/truncating it.
    static func partition(byteCounts: [Int], budget: Int) -> [[Int]] {
        guard !byteCounts.isEmpty else { return [] }
        let limit = max(1, budget)
        var result: [[Int]] = [], block: [Int] = [], size = 0
        for index in byteCounts.indices {
            let count = max(0, byteCounts[index])
            if !block.isEmpty && (count > limit || size > limit - count) {
                result.append(block); block = []; size = 0
            }
            block.append(index)
            size = count > Int.max - size ? Int.max : size + count
            if size >= limit { result.append(block); block = []; size = 0 }
        }
        if !block.isEmpty { result.append(block) }
        return result
    }
    static func sourceID(index: Int) -> String { "S\(index + 1)" }
    static func citationsAreValid(body: String, citations: [String], allowed: Set<String>) -> Bool {
        let inline = IntelligenceMath.sourceTags(in: body)
        return !citations.isEmpty && !inline.isEmpty && Set(citations).isSubset(of: allowed) && inline.isSubset(of: Set(citations))
    }
}

enum IntelligenceError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

enum IntelligenceMath {
    static func sourceTags(in text: String) -> Set<String> {
        guard let pattern = try? NSRegularExpression(pattern: "\\[(S[0-9]+)\\]") else { return [] }
        let ns = text as NSString
        return Set(pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range(at: 1))
        })
    }
    static func cosineSimilarity(_ a: [Double], _ b: [Double]) -> Double? {
        guard a.count == b.count, !a.isEmpty,
              a.allSatisfy(\.isFinite), b.allSatisfy(\.isFinite) else { return nil }
        let dot = zip(a, b).reduce(0.0) { $0 + $1.0 * $1.1 }
        let aa = a.reduce(0.0) { $0 + $1 * $1 }, bb = b.reduce(0.0) { $0 + $1 * $1 }
        guard aa > 0, bb > 0 else { return nil }
        return max(-1, min(1, dot / sqrt(aa * bb)))
    }

    static func keywordScore(query: String, text: String) -> Double {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return 0 }
        return text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) == nil ? 0 : 1
    }
}
