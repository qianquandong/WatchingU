import XCTest
@testable import ClipStorage

final class StoredZIPTests: XCTestCase {
    func testArchivePassesIndependentUnzipAndPreservesUnicodeBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("input")
        let content = Data("录音原文\nhello\0".utf8)
        try content.write(to: source)
        let zip = root.appendingPathComponent("out.zip")
        try StoredZIP.write(entries: [.init(name: "转写/今天.txt", source: source)], to: zip)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", zip.path, "转写/今天.txt"]
        let pipe = Pipe(); process.standardOutput = pipe
        try process.run()
        let result = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0); XCTAssertEqual(result, content)
    }
    func testUnsafeAndDuplicateNamesFailWithoutLeavingArchive() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("input"); try Data([1,2,3]).write(to: source)
        for entries in [[StoredZIP.Entry(name: "../escape", source: source)],
                        [.init(name: "one", source: source), .init(name: "one", source: source)]] {
            let destination = root.appendingPathComponent("out.zip")
            XCTAssertThrowsError(try StoredZIP.write(entries: entries, to: destination))
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }
}
