import XCTest
@testable import ClipStorage

final class IntelligenceTests: XCTestCase {
    func testDefaultSettingsDoNotAuthorizeNetworkOrAutomaticProcessing() throws {
        let value = IntelligenceSettings()
        XCTAssertFalse(value.remoteAIEnabled)
        XCTAssertFalse(value.automaticTranscription)
        XCTAssertFalse(value.automaticReview)
        XCTAssertTrue(value.apiBaseURL.isEmpty)
        XCTAssertTrue(value.model.isEmpty)
        let json = String(data: try JSONEncoder().encode(value), encoding: .utf8)!
        XCTAssertFalse(json.localizedCaseInsensitiveContains("apikey"))
    }

    func testPartialTranscriptCheckpointPreservesStableSourceAndOffset() throws {
        let clip = UUID(), segmentID = UUID()
        let segment = TranscriptSegment(id: segmentID, offset: 32.5, duration: 6.2, text: "下周三交付")
        let original = TranscriptDocument(clipID: clip, startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            duration: 60, localeIdentifier: "zh-CN", sourceSHA256: String(repeating: "a", count: 64),
            segments: [segment], completedOffset: 50, isComplete: false)
        let copy = try JSONDecoder().decode(TranscriptDocument.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(copy, original)
        XCTAssertEqual(copy.completedOffset, 50)
        XCTAssertFalse(copy.isComplete)
        XCTAssertEqual(copy.segments.first?.id, segmentID)
        XCTAssertEqual(copy.clipID, clip)
    }

    func testTranscriptWithoutSpeakerFieldsDecodesForLaterSpeakerProcessing() throws {
        let original = TranscriptSegment(offset: 10, duration: 2, text: "hello")
        let data = try JSONEncoder().encode(original)
        let copy = try JSONDecoder().decode(TranscriptSegment.self, from: data)
        XCTAssertNil(copy.speakerID)
        XCTAssertNil(copy.speakerLabel)
        XCTAssertEqual(copy.offset, 10)
    }

    func testCosineRejectsInvalidDimensionsZeroAndNonfiniteInputs() {
        XCTAssertNil(IntelligenceMath.cosineSimilarity([1], [1, 2]))
        XCTAssertNil(IntelligenceMath.cosineSimilarity([0, 0], [1, 2]))
        XCTAssertNil(IntelligenceMath.cosineSimilarity([.nan], [1]))
        XCTAssertEqual(IntelligenceMath.cosineSimilarity([1, 2], [2, 4])!, 1, accuracy: 0.00001)
        XCTAssertEqual(IntelligenceMath.cosineSimilarity([1, 0], [-1, 0])!, -1, accuracy: 0.00001)
    }

    func testKeywordSearchSupportsChineseAndCaseInsensitiveLatinText() {
        XCTAssertEqual(IntelligenceMath.keywordScore(query: "交付", text: "下周三交付"), 1)
        XCTAssertEqual(IntelligenceMath.keywordScore(query: "  meeting\n", text: "Meeting on Monday"), 1)
        XCTAssertEqual(IntelligenceMath.keywordScore(query: "", text: "anything"), 0)
        XCTAssertEqual(IntelligenceMath.keywordScore(query: "欠款", text: "下周三交付"), 0)
    }

    func testSourceTagValidationCannotMistakeUUIDOrArbitraryLinksForEvidence() {
        XCTAssertEqual(IntelligenceMath.sourceTags(in: "决定 [S1]，待办 [S12]；重复 [S1]"), Set(["S1", "S12"]))
        XCTAssertTrue(IntelligenceMath.sourceTags(in: "[source] [Sx] [not evidence](https://example.com)").isEmpty)
        XCTAssertFalse(IntelligenceMath.sourceTags(in: "事实 [S999]").isSubset(of: Set(["S1", "S2"])))
    }
}
