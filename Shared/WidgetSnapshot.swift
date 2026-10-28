import Foundation

/// Only counters and an optional user-approved title cross into the widget container.
struct DayTapeWidgetSnapshot: Codable, Equatable {
    var updatedAt = Date()
    var recordedSeconds: Double = 0
    var clipCount: Int = 0
    var pendingCount: Int = 0
    var recordingState = "准备好了"
    var reviewTitle: String? = nil
}

enum WidgetSnapshotStore {
    static var appGroup: String {
        guard Bundle.main.object(forInfoDictionaryKey: "DayTapeFeatureSet") as? String != "core-testing" else { return "" }
        return Bundle.main.object(forInfoDictionaryKey: "DayTapeAppGroup") as? String ?? ""
    }
    static func save(_ snapshot: DayTapeWidgetSnapshot) {
        guard !appGroup.isEmpty, let defaults = UserDefaults(suiteName: appGroup),
              let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: "daytape.widget.snapshot")
    }
    static func load() -> DayTapeWidgetSnapshot? {
        guard !appGroup.isEmpty, let data = UserDefaults(suiteName: appGroup)?.data(forKey: "daytape.widget.snapshot") else { return nil }
        return try? JSONDecoder().decode(DayTapeWidgetSnapshot.self, from: data)
    }
}
