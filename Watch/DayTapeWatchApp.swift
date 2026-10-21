import SwiftUI
import WatchKit

final class WatchServices: ObservableObject {
    static let shared = WatchServices()
    let recorder: WatchRecorder?
    let transport: Connectivity?
    let startupError: String?
    init() {
        do {
            let store = try ClipStore(); try store.recover()
            let link = Connectivity(store: store)
            transport = link; recorder = WatchRecorder(store: store, transport: link); startupError = nil
        } catch { recorder = nil; transport = nil; startupError = error.localizedDescription }
    }
}

final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() { _ = WatchServices.shared; _ = DailyNotifications.shared }
    func applicationDidBecomeActive() {
        WatchServices.shared.recorder?.reconcile()
        WatchServices.shared.transport?.pump()
    }
    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        WatchServices.shared.recorder?.reconcile()
        WatchServices.shared.transport?.pump(force: true)
        for task in backgroundTasks { task.setTaskCompletedWithSnapshot(false) }
    }
}

@main
struct DayTapeWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var appDelegate
    @StateObject private var services = WatchServices.shared
    var body: some Scene {
        WindowGroup {
            if let recorder = services.recorder, let transport = services.transport {
                WatchHome(recorder: recorder, transport: transport)
            } else {
                ScrollView { Text("无法打开录音存储\n" + (services.startupError ?? "请重新打开应用")) }
            }
        }
    }
}

struct WatchHome: View {
    @ObservedObject var recorder: WatchRecorder
    @ObservedObject var transport: Connectivity
    @Environment(\.scenePhase) private var scenePhase
    private let mint = Color(red: 0.55, green: 0.94, blue: 0.77)
    private var elapsed: String {
        let seconds = Int(recorder.recordedSeconds)
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                HStack { Text("DAYTAPE").font(.caption2).tracking(2); Spacer(); Image(systemName: "waveform") }
                    .foregroundStyle(mint)
                HStack(spacing: 6) {
                    Circle().fill(recorder.phase == .recording ? Color.red : Color.gray).frame(width: 6, height: 6)
                    Text(stateTitle).font(.caption)
                }
                Text(elapsed).font(.system(size: 26, weight: .medium, design: .monospaced)).minimumScaleFactor(0.6)
                if recorder.phase == .recording {
                    Button(role: .destructive) { recorder.stop() } label: {
                        Label("停止并保存", systemImage: "stop.fill").frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).tint(.red)
                } else {
                    Button { recorder.start() } label: {
                        Label("开始录音", systemImage: "mic.fill").frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).tint(mint).foregroundStyle(.black)
                        .disabled(recorder.busy)
                }
                VStack(spacing: 4) {
                    Text("待手机确认 \(transport.pendingCount) 段").font(.caption)
                    Text(transport.status).font(.caption2).foregroundStyle(.secondary)
                    Button("立即同步") { transport.pump(force: true, manualOverride: true) }.font(.caption2)
                }
                if let notice = recorder.notice {
                    Text(notice).font(.caption2).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
                }
                if let error = transport.errorText {
                    Text(error).font(.caption2).foregroundStyle(.orange)
                }
                Text(recorder.routineStatus).font(.caption2).foregroundStyle(.secondary)
                Button("启用每日提醒") { recorder.configureRoutine() }.font(.caption2)
            }.padding(.horizontal, 3)
        }
        .task { recorder.restoreRoutine(); recorder.reconcile(); transport.pump() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { recorder.reconcile(); transport.pump() }
        }
    }
    private var stateTitle: String {
        switch recorder.phase {
        case .idle: return "准备好了"
        case .authorizing: return "正在准备麦克风"
        case .recording: return "正在录音"
        case .finishing: return "正在保存"
        case .interrupted: return "录音已中断"
        }
    }
}
