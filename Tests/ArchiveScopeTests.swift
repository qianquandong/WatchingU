import XCTest
@testable import ClipStorage

final class ArchiveScopeTests: XCTestCase {
    func testUncitedOutsideInputStillExcludesAIResult() {
        let selected = UUID(), outside = UUID()
        XCTAssertFalse(ArchiveScopePolicy.permits([selected, outside], within: [selected]))
        XCTAssertTrue(ArchiveScopePolicy.permits([selected], within: [selected]))
    }
    func testUnknownLegacyAndEmptyInputAreNeverAssumedInScope() {
        let selected = UUID()
        XCTAssertFalse(ArchiveScopePolicy.permits(nil, within: [selected]))
        XCTAssertFalse(ArchiveScopePolicy.permits([], within: [selected]))
        XCTAssertFalse(ArchiveScopePolicy.permits([selected], within: []))
    }
}
