import AppIntents
import Foundation

/// Shortcuts and the Ultra Action Button open the app; the recorder still checks foreground state.
struct StartDayTapeRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "开始 DayTape 录音"
    static var description = IntentDescription("打开 DayTape，在手表前台开始录音。")
    static var openAppWhenRun = true
    @MainActor
    func perform() async throws -> some IntentResult {
        let requested = Date()
        UserDefaults.standard.set(requested, forKey: "daytape.pending.record.intent")
        NotificationCenter.default.post(name: .dailyStartRequested, object: nil,
            userInfo: ["requestedAt":requested])
        return .result()
    }
}

struct DayTapeWatchShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartDayTapeRecordingIntent(),
            phrases: ["用 \(.applicationName) 开始录音", "Start recording with \(.applicationName)"],
            shortTitle: "开始录音", systemImageName: "mic.fill")
    }
}
