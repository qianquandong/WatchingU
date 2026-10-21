import Foundation
#if SWIFT_PACKAGE
import RecorderRules
#endif

struct Clip: Codable, Identifiable {
    let id: UUID
    let sessionID: UUID
    let startedAt: Date
    let duration: Double
    let byteCount: UInt64
    let sha256: String
    var attempts: UInt32 = 0
    var retryAfter: Date = .distantPast
    var fileName: String { id.uuidString + ".m4a" }

    var isValid: Bool {
        duration.isFinite && duration > 0 && duration < 180 && byteCount > 0 &&
        byteCount < 16 * 1024 * 1024 && sha256.count == 64 &&
        sha256.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}

struct Receipt: Codable {
    let clipID: UUID
    let sha256: String
    let byteCount: UInt64
    let savedAt: Date
    init(clip: Clip) {
        clipID = clip.id; sha256 = clip.sha256; byteCount = clip.byteCount; savedAt = Date()
    }
    func matches(_ clip: Clip) -> Bool {
        clip.id.uuidString.withCString { localID in
            clip.sha256.withCString { localHash in
                clipID.uuidString.withCString { remoteID in
                    sha256.withCString { remoteHash in
                        rr_receipt_matches(localID, localHash, clip.byteCount,
                                           remoteID, remoteHash, byteCount) != 0
                    }
                }
            }
        }
    }
}

struct CaptureDraft: Codable {
    let id: UUID
    let sessionID: UUID
    let startedAt: Date
}

enum ArchiveError: LocalizedError {
    case invalidMetadata, checksumMismatch, conflict, storageBudget, encoding, backlog
    var errorDescription: String? {
        switch self {
        case .invalidMetadata: return "录音资料不完整，原文件已保留。"
        case .checksumMismatch: return "录音校验失败，等待手表重新传输。"
        case .conflict: return "同一录音出现不同内容，已停止覆盖。"
        case .storageBudget: return "存储空间或待传缓存达到上限，录音已停止。"
        case .encoding: return "音频编码失败，请重新开始录音。"
        case .backlog: return "写入跟不上采集，已停止，避免静默丢失音频。"
        }
    }
}

extension Notification.Name {
    static let archiveChanged = Notification.Name("daytape.archive.changed")
}
