import SwiftUI
import AVFoundation
import GoogleSignIn
import UIKit

@MainActor
final class PhoneServices: ObservableObject {
    static let shared = PhoneServices()
    let archive: NightArchiveController?
    let store: ClipStore?
    let transport: Connectivity?
    let startupError: String?
    init() {
        do {
            let local = try ClipStore()
            let cloud = try NightArchiveController(store: local)
            store = local; transport = Connectivity(store: local)
            archive = cloud; startupError = nil
        } catch { store = nil; transport = nil; archive = nil; startupError = error.localizedDescription }
    }
}

@MainActor
final class PhoneAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        PhoneServices.shared.archive?.registerBackgroundTasks(); return true
    }
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard let archive = PhoneServices.shared.archive else { completionHandler(); return }
        archive.handleBackgroundSession(identifier: identifier, completion: completionHandler)
    }
}

@main
struct DayTapePhoneApp: App {
    @UIApplicationDelegateAdaptor(PhoneAppDelegate.self) private var appDelegate
    @StateObject private var services = PhoneServices.shared
    var body: some Scene {
        WindowGroup {
            if let store = services.store, let transport = services.transport, let archive = services.archive {
                PhoneHome(store: store, transport: transport, archive: archive).preferredColorScheme(.dark)
                    .onOpenURL { _ = GIDSignIn.sharedInstance.handle($0) }
            } else {
                ContentUnavailableView("无法打开存储", systemImage: "externaldrive.badge.exclamationmark",
                                       description: Text(services.startupError ?? "请重新打开应用"))
            }
        }
    }
}

final class Playback: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var playingID: UUID?
    @Published var errorText: String?
    private var player: AVAudioPlayer?
    private var pinnedStore: ClipStore?
    private var pinnedID: UUID?
    func toggle(_ clip: Clip, store: ClipStore) {
        if playingID == clip.id { stop(); return }
        do {
            stop()
            guard store.retainAudio(clip.id) else { throw ArchiveError.encoding }
            pinnedStore = store; pinnedID = clip.id
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            let next = try AVAudioPlayer(contentsOf: store.audioURL(clip.id))
            next.delegate = self
            guard next.prepareToPlay(), next.play() else { throw ArchiveError.encoding }
            player = next; playingID = clip.id; errorText = nil
        } catch { stop(); errorText = error.localizedDescription }
    }
    func stop() {
        player?.stop(); player = nil; playingID = nil
        if let id = pinnedID { pinnedStore?.releaseAudio(id) }; pinnedID = nil; pinnedStore = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { self.stop() }
    }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        DispatchQueue.main.async { self.stop(); self.errorText = error?.localizedDescription ?? "音频无法播放" }
    }
}

struct PhoneHome: View {
    let store: ClipStore
    @ObservedObject var transport: Connectivity
    @ObservedObject var archive: NightArchiveController
    @State private var exportClip: Clip?
    @State private var exportID: UUID?
    @StateObject private var playback = Playback()
    @Environment(\.scenePhase) private var scenePhase
    @State private var clips: [Clip] = []
    @State private var loadError: String?
    private let mint = Color(red: 0.55, green: 0.94, blue: 0.77)
    private var groups: [(Date, [Clip])] {
        Dictionary(grouping: clips) { Calendar.current.startOfDay(for: $0.startedAt) }
            .sorted { $0.key > $1.key }.map { ($0.key, $0.value.sorted { $0.startedAt > $1.startedAt }) }
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("一天的声音，留在身边。")
                            .font(.system(size: 28, weight: .semibold)).tracking(-1)
                        Label(transport.status, systemImage: "applewatch.radiowaves.left.and.right")
                            .font(.caption).foregroundStyle(mint)
                        HStack(spacing: 25) {
                            metric("已保存", value: "\(clips.count) 段")
                            metric("总时长", value: "\(Int(clips.reduce(0) { $0 + $1.duration } / 60)) 分钟")
                        }
                    }.padding(.vertical, 10)
                }.listRowBackground(Color.clear)
                Section {
                    NavigationLink { ArchiveSettingsView(archive: archive, connection: archive.connection) } label: {
                        Label("录音与备份", systemImage: "moon.stars")
                    }
                    Text(archive.status).font(.caption).foregroundStyle(.secondary)
                    Text("本地 \(archive.localCount) 段 · 云端已验证 \(archive.cloudCount) 段").font(.caption)
                }
                if let error = loadError ?? transport.errorText ?? playback.errorText {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                }
                if clips.isEmpty {
                    Section {
                        ContentUnavailableView("暂无录音", systemImage: "waveform")
                    }
                }
                ForEach(groups, id: \.0) { day, recordings in
                    Section(day.formatted(date: .abbreviated, time: .omitted)) {
                        ForEach(recordings) { clip in
                            HStack(spacing: 15) {
                                Button { playback.toggle(clip, store: store) } label: {
                                    Image(systemName: playback.playingID == clip.id ? "stop.circle.fill" : "play.circle.fill")
                                        .font(.system(size: 36)).foregroundStyle(mint)
                                }.buttonStyle(.plain).disabled(!store.hasLocalAudio(clip.id))
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(clip.startedAt.formatted(date: .omitted, time: .standard)).font(.headline)
                                    Text("\(Int(clip.duration)) 秒 · \(ByteCountFormatter.string(fromByteCount: Int64(clip.byteCount), countStyle: .file))")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text(store.hasLocalAudio(clip.id) ? "保存在本机" : "云端归档 · 已释放本地音频").font(.caption2).foregroundStyle(mint)
                                }
                                Spacer()
                                if store.hasLocalAudio(clip.id) {
                                    Button {
                                        if store.retainAudio(clip.id) { exportID = clip.id; exportClip = clip }
                                    } label: { Image(systemName: "square.and.arrow.up") }
                                    .buttonStyle(.borderless).accessibilityLabel("导出这段录音")
                                } else if let url = store.cloudReceipt(clip.id)?.viewURL {
                                    Link(destination: url) { Image(systemName: "icloud") }
                                }
                            }.padding(.vertical, 7)
                        }
                    }
                }
            }
            .navigationTitle("DayTape")
            .toolbar { Button { refresh(); transport.refresh() } label: { Image(systemName: "arrow.clockwise") } }
            .task { refresh(); await archive.wake() }
            .sheet(item: $exportClip, onDismiss: {
                if let id = exportID { store.releaseAudio(id) }; exportID = nil
            }) { clip in AudioExport(url: store.audioURL(clip.id)) }
            .onReceive(NotificationCenter.default.publisher(for: .archiveDisplayChanged)) { _ in refresh() }
            .onReceive(NotificationCenter.default.publisher(for: .archiveChanged)) { _ in refresh() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { refresh(); transport.refresh(); Task { await archive.wake() } } }
        }.tint(mint)
    }
    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.title3.monospacedDigit()).bold()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }
    private func refresh() {
        do { clips = try store.clips(); loadError = nil }
        catch { loadError = error.localizedDescription }
    }
}


struct AudioExport: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
