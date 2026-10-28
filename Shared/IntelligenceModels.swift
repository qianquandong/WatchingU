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
    var backendIdentifier: String? = nil
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
    var pendingTranscriptCount: Int? = nil
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
    enum TranscriptionBackend: String, Codable, CaseIterable, Identifiable {
        case onDevice, configuredService
        var id: String { rawValue }
        var title: String { self == .onDevice ? "本机" : "我的转写服务" }
    }
    var localeIdentifier: String = "zh-CN"
    var automaticTranscription: Bool = false
    // Saving an endpoint or a key alone never permits a network request.
    var remoteAIEnabled: Bool = false
    var apiBaseURL: String = ""
    var model: String = ""
    var automaticReview: Bool = false
    var transcriptionBackend: TranscriptionBackend? = nil
    var remoteASRSharingEnabled: Bool? = nil
    var remoteASRBaseURL: String? = nil
    var remoteASRModel: String? = nil
    var remoteASRLanguage: String? = nil
    var remoteASRResponseFormat: String? = nil

    init() {}
    enum CodingKeys: String, CodingKey {
        case localeIdentifier, automaticTranscription, remoteAIEnabled, apiBaseURL, model, automaticReview
        case transcriptionBackend, remoteASRSharingEnabled, remoteASRBaseURL, remoteASRModel, remoteASRLanguage, remoteASRResponseFormat
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        localeIdentifier = try values.decodeIfPresent(String.self, forKey: .localeIdentifier) ?? "zh-CN"
        automaticTranscription = try values.decodeIfPresent(Bool.self, forKey: .automaticTranscription) ?? false
        remoteAIEnabled = try values.decodeIfPresent(Bool.self, forKey: .remoteAIEnabled) ?? false
        apiBaseURL = try values.decodeIfPresent(String.self, forKey: .apiBaseURL) ?? ""
        model = try values.decodeIfPresent(String.self, forKey: .model) ?? ""
        automaticReview = try values.decodeIfPresent(Bool.self, forKey: .automaticReview) ?? false
        transcriptionBackend = try values.decodeIfPresent(TranscriptionBackend.self, forKey: .transcriptionBackend)
        remoteASRSharingEnabled = try values.decodeIfPresent(Bool.self, forKey: .remoteASRSharingEnabled)
        remoteASRBaseURL = try values.decodeIfPresent(String.self, forKey: .remoteASRBaseURL)
        remoteASRModel = try values.decodeIfPresent(String.self, forKey: .remoteASRModel)
        remoteASRLanguage = try values.decodeIfPresent(String.self, forKey: .remoteASRLanguage)
        remoteASRResponseFormat = try values.decodeIfPresent(String.self, forKey: .remoteASRResponseFormat)
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

struct ConfiguredSpeechResponse: Decodable {
    struct Segment: Decodable { let start: Double; let end: Double; let text: String }
    let text: String?
    let segments: [Segment]?
    func transcriptSegments(offset: Double, duration: Double) throws -> [TranscriptSegment] {
        guard offset.isFinite, offset >= 0, duration.isFinite, duration > 0,
              text != nil || segments != nil else { throw IntelligenceError.message("转写服务响应缺少有效文字或分段。") }
        if let parts = segments, !parts.isEmpty {
            guard parts.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start && $0.end <= duration + 0.3 }) else {
                throw IntelligenceError.message("转写服务返回的时间戳超出录音窗口，未保存。")
            }
            return parts.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map {
                TranscriptSegment(offset: offset + $0.start, duration: max(0, min(duration, $0.end) - $0.start), text: $0.text)
            }.sorted { $0.offset < $1.offset }
        }
        let text = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? [] : [TranscriptSegment(offset: offset, duration: duration, text: text)]
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
