import Foundation

/// A request gate, not a promise that iOS will wake the app when a charger is attached.
enum BackupPowerState: Equatable {
    case unknown, unplugged, charging, full
    var connectedToPower: Bool { self == .charging || self == .full }
}

struct ChargingBackupPolicy {
    static let reminderDelay: TimeInterval = 24 * 60 * 60

    static func allowsRequest(enabled: Bool, power: BackupPowerState, wifiOnly: Bool,
                              wifiAvailable: Bool, runtimeAvailable: Bool, manualBatch: Bool) -> Bool {
        enabled && runtimeAvailable && (!wifiOnly || wifiAvailable) && (manualBatch || power.connectedToPower)
    }

    /// A manual action covers only the clips already sealed when the user pressed the button.
    static func manualBatchContains(clipEnd: Date, requestedThrough: Date?) -> Bool {
        guard let cutoff = requestedThrough, clipEnd.timeIntervalSince1970.isFinite,
              cutoff.timeIntervalSince1970.isFinite else { return false }
        return clipEnd <= cutoff
    }

    static func reminderDate(oldestPendingEnd: Date, lastScheduledAlert: Date?) -> Date? {
        guard oldestPendingEnd.timeIntervalSince1970.isFinite else { return nil }
        let due = oldestPendingEnd.addingTimeInterval(reminderDelay)
        guard let previous = lastScheduledAlert, previous.timeIntervalSince1970.isFinite else { return due }
        return max(due, previous.addingTimeInterval(reminderDelay))
    }
}
