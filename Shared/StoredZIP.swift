import Foundation

/// Streaming, uncompressed ZIP writer. Audio is already AAC; no extra codec pass is needed.
/// ZIP32 bounds are checked before writing so a large export fails without a corrupt archive.
final class StoredZIP {
    struct Entry {
        let name: String
        let source: URL
    }
    enum Failure: Error { case invalidName, tooLarge, fileChanged }
    private struct Record { let name: Data; let crc: UInt32; let size: UInt32; let offset: UInt32 }
    private static func integer<T: FixedWidthInteger>(_ value: T) -> Data {
        var little = value.littleEndian
        return withUnsafeBytes(of: &little) { Data($0) }
    }
    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = (value >> 1) ^ (0xedb88320 & (0 &- (value & 1))) }
        return value
    }
    private static func checksum(_ data: Data, previous: UInt32) -> UInt32 {
        var crc = previous
        for byte in data { crc = (crc >> 8) ^ crcTable[Int((crc ^ UInt32(byte)) & 0xff)] }
        return crc
    }
    static func write(entries: [Entry], to destination: URL) throws {
        try Task.checkCancellation()
        guard entries.count <= Int(UInt16.max) else { throw Failure.tooLarge }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        var succeeded = false
        defer { try? output.close(); if !succeeded { try? FileManager.default.removeItem(at: destination) } }
        var records: [Record] = []
        var seen = Set<String>()
        for entry in entries {
            try Task.checkCancellation()
            let name = Data(entry.name.utf8)
            guard !name.isEmpty, name.count <= Int(UInt16.max), !entry.name.hasPrefix("/"),
                  !entry.name.contains("\\"), !entry.name.contains("\0"),
                  !entry.name.split(separator: "/").contains(".."), seen.insert(entry.name).inserted else { throw Failure.invalidName }
            let source = try FileHandle(forReadingFrom: entry.source)
            defer { try? source.close() }
            var crc: UInt32 = 0xffffffff
            var bytes: UInt64 = 0
            while let block = try source.read(upToCount: 256 * 1024), !block.isEmpty {
                try Task.checkCancellation()
                crc = checksum(block, previous: crc); bytes += UInt64(block.count)
            }
            let offset = try output.offset()
            guard bytes <= UInt64(UInt32.max), offset <= UInt64(UInt32.max) else { throw Failure.tooLarge }
            let size = UInt32(bytes); crc ^= 0xffffffff
            // UTF-8 names, store method, DOS epoch 1980-01-01.
            try output.write(contentsOf: integer(UInt32(0x04034b50)))
            for value in [UInt16(20), 0x0800, 0, 0, 0x0021] { try output.write(contentsOf: integer(value)) }
            for value in [crc, size, size] { try output.write(contentsOf: integer(value)) }
            try output.write(contentsOf: integer(UInt16(name.count)))
            try output.write(contentsOf: integer(UInt16(0))); try output.write(contentsOf: name)
            try source.seek(toOffset: 0)
            var copied: UInt64 = 0; var copiedCRC: UInt32 = 0xffffffff
            while let block = try source.read(upToCount: 256 * 1024), !block.isEmpty {
                try Task.checkCancellation()
                try output.write(contentsOf: block); copied += UInt64(block.count)
                copiedCRC = checksum(block, previous: copiedCRC)
            }
            guard copied == bytes, (copiedCRC ^ 0xffffffff) == crc else { throw Failure.fileChanged }
            records.append(Record(name: name, crc: crc, size: size, offset: UInt32(offset)))
        }
        let centralStart = try output.offset()
        guard centralStart <= UInt64(UInt32.max) else { throw Failure.tooLarge }
        for record in records {
            try Task.checkCancellation()
            try output.write(contentsOf: integer(UInt32(0x02014b50)))
            for value in [UInt16(20), 20, 0x0800, 0, 0, 0x0021] { try output.write(contentsOf: integer(value)) }
            for value in [record.crc, record.size, record.size] { try output.write(contentsOf: integer(value)) }
            for value in [UInt16(record.name.count), 0, 0, 0, 0] { try output.write(contentsOf: integer(value)) }
            try output.write(contentsOf: integer(UInt32(0)))
            try output.write(contentsOf: integer(record.offset)); try output.write(contentsOf: record.name)
        }
        let end = try output.offset()
        guard end <= UInt64(UInt32.max), end - centralStart <= UInt64(UInt32.max) else { throw Failure.tooLarge }
        try output.write(contentsOf: integer(UInt32(0x06054b50)))
        for value in [UInt16(0), 0, UInt16(records.count), UInt16(records.count)] { try output.write(contentsOf: integer(value)) }
        try output.write(contentsOf: integer(UInt32(end - centralStart)))
        try output.write(contentsOf: integer(UInt32(centralStart)))
        try output.write(contentsOf: integer(UInt16(0)))
        try output.synchronize(); succeeded = true
    }
}
