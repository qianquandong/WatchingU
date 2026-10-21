import Foundation
#if SWIFT_PACKAGE
import RecorderRules
#endif

struct CloudReceipt: Codable {
    let clipID: UUID
    let fileID: String
    let metadataFileID: String
    let accountID: String
    let byteCount: UInt64
    let sha256: String
    let verifiedAt: Date
    func matches(_ clip: Clip) -> Bool {
        guard !fileID.isEmpty, !metadataFileID.isEmpty, !accountID.isEmpty else { return false }
        return clip.id.uuidString.withCString { a in clip.sha256.withCString { b in
            clipID.uuidString.withCString { c in sha256.withCString { d in
                rr_receipt_matches(a, b, clip.byteCount, c, d, byteCount) != 0
            }}
        }}
    }
    var viewURL: URL? { URL(string: "https://drive.google.com/file/d/\(fileID)/view") }
}

struct ArchiveSettings: Codable {
    var enabled = false
    var useSleepRecords = false
    var requestedSleepAccess = false
    var fallbackEnabled = false
    var fallbackHour = 2
    var fallbackMinute = 0
    var wifiOnly = true
    var purgeAfterVerification = true
    var archiveThrough: Date? = nil
    var lastSleepEvidence: Date? = nil
    var lastFallbackDay: String? = nil
    var uploadClock: BackupClock? = nil
    func resolvedUploadClock(for recording: DailySchedule) -> BackupClock {
        uploadClock ?? BackupClock(hour: recording.stopHour, minute: recording.stopMinute)
    }
}

struct UploadArtifact: Codable {
    enum Phase: String, Codable { case pending, transferring, needsVerification, verified }
    let fileID: String
    let localName: String
    let mimeType: String
    let byteCount: UInt64
    let sha256: String
    var phase: Phase = .pending
    var sessionURL: URL? = nil
}

struct ArchiveJob: Codable {
    let clipID: UUID
    let accountID: String
    let folderID: String
    let dayKey: String
    var audio: UploadArtifact
    var metadata: UploadArtifact
    var attempts: UInt32 = 0
    var retryAfter: Date = .distantPast
    var lastError: String? = nil
    var complete: Bool { audio.phase == .verified && metadata.phase == .verified }
}

enum CloudArchiveError: LocalizedError {
    case setupRequired, signInRequired, accountChanged, invalidResponse, remoteMismatch, http(Int), cancelled
    var errorDescription: String? {
        switch self {
        case .setupRequired: return "云端备份暂不可用。你可以继续本地录音，稍后再试。"
        case .signInRequired: return "请连接 Google Drive，授权失效时需重新连接。"
        case .accountChanged: return "Google 账户与归档任务不一致，已保留本地录音。请连接原账户。"
        case .invalidResponse: return "云盘响应无法验证，录音保留在本地。"
        case .remoteMismatch: return "云端大小或 SHA-256 未通过校验，本地录音未清理。"
        case .http(let code):
            if code == 401 { return "Google Drive 连接已过期，请重新连接。本地录音会保留。" }
            if code == 403 { return "Google Drive 暂不允许上传。请检查账户权限或剩余空间；本地录音会保留。" }
            return "云端暂时无法完成备份，稍后自动重试。本地录音会保留。"
        case .cancelled: return "操作已取消，录音保留在本地。"
        }
    }
}

struct DriveFile: Decodable {
    let id: String
    let size: String?
    let sha256Checksum: String?
    let trashed: Bool?
    func verifies(_ artifact: UploadArtifact) -> Bool {
        guard id == artifact.fileID, trashed == false,
              let size = size, UInt64(size) == artifact.byteCount,
              let hash = sha256Checksum else { return false }
        return hash.lowercased() == artifact.sha256
    }
}
