import Foundation

/// The limited testing variant must never present omitted capabilities as available.
enum AppBuildFeatures {
    static var coreTesting: Bool {
        Bundle.main.object(forInfoDictionaryKey: "DayTapeFeatureSet") as? String == "core-testing"
    }
    static var widgetsAvailable: Bool {
        !coreTesting && !WidgetSnapshotStore.appGroup.isEmpty
    }
}
