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

    func testLongDayPartitionCoversEverySourceExactlyOnceInOrder() {
        let sizes = (0..<2041).map { 40 + (($0 * 173) % 900) }
        let blocks = AIContextPlanner.partition(byteCounts: sizes, budget: 32_000)
        let flattened = blocks.flatMap { $0 }
        XCTAssertEqual(flattened, Array(sizes.indices))
        XCTAssertEqual(Set(flattened).count, sizes.count)
        XCTAssertTrue(blocks.allSatisfy { !$0.isEmpty && $0.reduce(0) { $0 + sizes[$1] } <= 32_000 })
    }

    func testOversizedSourceIsPreservedAsItsOwnBlockRatherThanTruncated() {
        let sizes = [10, 50_000, 8, 32_000, 1]
        let blocks = AIContextPlanner.partition(byteCounts: sizes, budget: 32_000)
        XCTAssertEqual(blocks.flatMap { $0 }, [0, 1, 2, 3, 4])
        XCTAssertTrue(blocks.contains([1]))
        XCTAssertEqual(AIContextPlanner.partition(byteCounts: [], budget: 1), [])
    }

    func testCitationIDsStayGlobalAcrossBlocksAndMergeCannotInventSources() {
        let blocks = AIContextPlanner.partition(byteCounts: [10, 10, 10, 10], budget: 20)
        let second = Set(blocks[1].map { AIContextPlanner.sourceID(index: $0) })
        XCTAssertEqual(second, Set(["S3", "S4"]))
        XCTAssertTrue(AIContextPlanner.citationsAreValid(body: "决定交付 [S3]，行动 [S4]", citations: ["S3", "S4"], allowed: second))
        XCTAssertFalse(AIContextPlanner.citationsAreValid(body: "虚构来源 [S1]", citations: ["S1"], allowed: second))
        XCTAssertFalse(AIContextPlanner.citationsAreValid(body: "无正文引用", citations: ["S3"], allowed: second))
        XCTAssertFalse(AIContextPlanner.citationsAreValid(body: "另一个引用 [S4]", citations: ["S3"], allowed: second))
    }

    func testInputDependenciesSurviveSerializationAndUnknownRemainUnknown() throws {
        let id = UUID()
        let review = AIReview(kind: .summary, day: Date(), title: "test", body: "content", citations: [], inputClipIDs: [id])
        let copy = try JSONDecoder().decode(AIReview.self, from: JSONEncoder().encode(review))
        XCTAssertEqual(copy.inputClipIDs, [id])
        let manualMemory = MemoryFact(text: "manually entered")
        let memory = try JSONDecoder().decode(MemoryFact.self, from: JSONEncoder().encode(manualMemory))
        XCTAssertNil(memory.inputClipIDs)
    }

    func testOldSettingsDefaultToOnDeviceWithoutAudioSharingAndConsentIsIndependent() throws {
        var value = try JSONDecoder().decode(IntelligenceSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(value.transcriptionBackend ?? .onDevice, .onDevice)
        XCTAssertNotEqual(value.remoteASRSharingEnabled, true)
        value.remoteAIEnabled = true
        XCTAssertNotEqual(value.remoteASRSharingEnabled, true)
        value.remoteASRSharingEnabled = true
        value.remoteAIEnabled = false
        XCTAssertEqual(value.remoteASRSharingEnabled, true)
    }

    func testConfiguredSpeechSegmentsMapWindowTimestampsToOriginalClip() throws {
        let json = #"{"text":"later earlier","segments":[{"start":4,"end":6,"text":"later"},{"start":1,"end":2,"text":"earlier"}]}"#
        let response = try JSONDecoder().decode(ConfiguredSpeechResponse.self, from: Data(json.utf8))
        let segments = try response.transcriptSegments(offset: 50, duration: 10)
        XCTAssertEqual(segments.map(\.offset), [51, 54])
        XCTAssertEqual(segments.map(\.duration), [1, 2])
        XCTAssertEqual(segments.map(\.text), ["earlier", "later"])
    }

    func testConfiguredSpeechTextOnlyResponseUsesWholeKnownWindowAndSilenceIsEmpty() throws {
        let response = try JSONDecoder().decode(ConfiguredSpeechResponse.self, from: Data(#"{"text":"真实服务文字"}"#.utf8))
        let segments = try response.transcriptSegments(offset: 50, duration: 10)
        XCTAssertEqual(segments.first?.offset, 50)
        XCTAssertEqual(segments.first?.duration, 10)
        XCTAssertEqual(segments.first?.text, "真实服务文字")
        let silence = try JSONDecoder().decode(ConfiguredSpeechResponse.self, from: Data(#"{"text":"","segments":[]}"#.utf8))
        XCTAssertTrue(try silence.transcriptSegments(offset: 0, duration: 50).isEmpty)
    }

    func testConfiguredSpeechRejectsMissingTextAndOutOfRangeTimestamps() throws {
        let invalid = try JSONDecoder().decode(ConfiguredSpeechResponse.self, from: Data(#"{"segments":[{"start":0,"end":500,"text":"wrong"}]}"#.utf8))
        XCTAssertThrowsError(try invalid.transcriptSegments(offset: 0, duration: 50))
        let missing = try JSONDecoder().decode(ConfiguredSpeechResponse.self, from: Data("{}".utf8))
        XCTAssertThrowsError(try missing.transcriptSegments(offset: 0, duration: 50))
    }
}
