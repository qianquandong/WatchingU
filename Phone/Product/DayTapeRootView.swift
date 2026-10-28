import SwiftUI
import WidgetKit
import UIKit

@MainActor
struct DayTapeRootView: View {
    @ObservedObject var services: PhoneServices
    let store: ClipStore
    @ObservedObject var transport: Connectivity
    @ObservedObject var archive: NightArchiveController
    @ObservedObject var intelligence: IntelligenceController
    @ObservedObject var context: PhoneContextService
    @ObservedObject var voice: VoiceIdentityService
    @ObservedObject var desktop: DesktopBridge
    @StateObject private var playback = Playback()
    @Environment(\.scenePhase) private var scenePhase
    @State private var clips: [Clip] = []
    @State private var loadError: String?
    @State private var showExport = false
    @State private var tab = 0
    @State private var lastWidgetUpdate = Date.distantPast
    @AppStorage("daytape.widget.showReviewTitle") private var widgetTitles = false
    private let mint = Color(red: 0.55, green: 0.94, blue: 0.77)
    private var groups: [(Date, [Clip])] {
        let calendar = DailySchedule().calendar
        return Dictionary(grouping: clips) { calendar.startOfDay(for: $0.startedAt) }
            .sorted { $0.key > $1.key }.map { ($0.key, $0.value.sorted { $0.startedAt > $1.startedAt }) }
    }
    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { library }.tabItem { Label("录音", systemImage: "waveform") }.tag(0)
            NavigationStack { ArchiveSearchView(controller: intelligence, store: store, playback: playback) }
                .tabItem { Label("搜索", systemImage: "magnifyingglass") }.tag(1)
            NavigationStack { DailyReviewsView(controller: intelligence, store: store, playback: playback) }
                .tabItem { Label("回顾", systemImage: "text.book.closed") }.tag(2)
            NavigationStack { settings }.tabItem { Label("设置", systemImage: "slider.horizontal.3") }.tag(3)
        }
        .tint(mint)
        .task { services.setForegroundActive(UIApplication.shared.applicationState == .active); refresh(); await archive.wake() }
        .onReceive(NotificationCenter.default.publisher(for: .archiveChanged)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .archiveDisplayChanged)) { _ in refresh() }
        .onChange(of: intelligence.reviews) { _, _ in updateWidget(force: true) }
        .onChange(of: scenePhase) { _, phase in
            services.setForegroundActive(phase == .active)
            if phase == .active { refresh(); transport.refresh(); Task { await archive.wake() } }
        }
        .onOpenURL { url in if url.scheme == "daytape" { tab = 0; refresh() } }
        .sheet(isPresented: $showExport) { BulkExportView(clips: clips, intelligence: intelligence, store: store) }
    }
    private var library: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("一天的声音，\n随时找得回来。")
                        .font(.system(size: 29, weight: .semibold, design: .serif)).tracking(-0.7)
                    HStack(spacing: 24) {
                        metric("已保存", "\(clips.count) 段")
                        metric("录音时长", "\(Int(clips.reduce(0) { $0 + $1.duration } / 60)) 分钟")
                    }
                    Label(transport.status, systemImage: "applewatch.radiowaves.left.and.right").font(.caption).foregroundStyle(mint)
                }.padding(.vertical, 10)
            }.listRowBackground(Color.clear)
            Section {
                Text(intelligence.status).font(.subheadline)
                if intelligence.isProcessing { ProgressView() }
                HStack {
                    Button(intelligence.isProcessing ? "暂停转写" : "转写待处理录音") {
                        if intelligence.isProcessing { intelligence.pauseTranscription() } else { intelligence.startTranscription() }
                    }
                    if intelligence.jobs.contains(where: { $0.state == .failed }) {
                        Button("重试") { intelligence.retryFailed() }
                    }
                }
                Text(archive.status).font(.caption).foregroundStyle(.secondary)
            } header: { Text("处理进度") }
            if intelligence.pendingDeletionCount > 0 {
                Section("删除清理") {
                    Text("有 \(intelligence.pendingDeletionCount) 条本机记录的删除清理尚未完成，相关内容已从检索中隐藏。")
                        .font(.subheadline)
                    if let message = intelligence.deletionCleanupError { Text(message).font(.caption).foregroundStyle(.orange) }
                    Button("重试清理本机数据") {
                        intelligence.retryPendingDeletions()
                        context.retryDeletedContextCleanup()
                    }
                }
            }
            if let error = loadError ?? transport.errorText ?? playback.errorText ?? intelligence.lastError {
                Section { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            }
            if clips.isEmpty {
                ContentUnavailableView("暂无录音", systemImage: "mic", description: Text("在手表上开始录音，已保存的片段会同步到这里。"))
            }
            ForEach(groups, id: \.0) { day, items in
                Section(day.formatted(date: .abbreviated, time: .omitted)) {
                    ForEach(items) { clip in
                        NavigationLink {
                            RecordingDetailView(clip: clip, store: store, intelligence: intelligence,
                                context: context, voice: voice, archive: archive, playback: playback)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: intelligence.documents.contains(where: { $0.clipID == clip.id && $0.isComplete }) ? "text.alignleft" : "waveform")
                                    .font(.title3).foregroundStyle(mint).frame(width: 28)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(clip.startedAt.formatted(date: .omitted, time: .standard)).font(.headline.monospacedDigit())
                                    if let text = intelligence.documents.first(where: { $0.clipID == clip.id })?.text, !text.isEmpty {
                                        Text(text).font(.subheadline).lineLimit(2).foregroundStyle(.secondary)
                                    } else {
                                        Text("\(Int(clip.duration)) 秒 · \(store.hasLocalAudio(clip.id) ? "原声在本机" : "原声在云端")").font(.caption).foregroundStyle(.secondary)
                                    }
                                    if !context.marks(for: clip).isEmpty { Label("含重要标记", systemImage: "bookmark.fill").font(.caption2).foregroundStyle(mint) }
                                }
                            }.padding(.vertical, 5)
                        }
                    }
                }
            }
        }
        .navigationTitle("DayTape")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button { refresh(); transport.refresh() } label: { Image(systemName: "arrow.clockwise") } }
            ToolbarItem(placement: .topBarTrailing) { Button { showExport = true } label: { Image(systemName: "square.and.arrow.up") }.disabled(clips.isEmpty).accessibilityLabel("批量导出") }
        }
    }
    private var settings: some View {
        Form {
            Section("录音与处理") {
                NavigationLink("备份与存储") { ArchiveSettingsView(archive: archive, connection: archive.connection) }
                NavigationLink("转写与 AI") { IntelligenceSettingsView(controller: intelligence) }
                NavigationLink("声音识别") { VoiceIdentitySettingsView(service: voice) }
                NavigationLink("个人记忆") { MemoriesView(controller: intelligence) }
            }
            Section("可选关联") {
                Toggle("关联 Apple 健康样本", isOn: Binding(get: { context.settings.healthEnabled }, set: { value in Task { await context.setHealthEnabled(value) } }))
                    .disabled(!context.healthAvailable)
                Toggle("记录大致地点", isOn: Binding(get: { context.settings.locationEnabled }, set: { context.setLocationEnabled($0) }))
                if let error = context.errorText { Text(error).font(.caption).foregroundStyle(.orange) }
                Text(context.status).font(.caption).foregroundStyle(.secondary)
            }
            Section("访问与导出") {
                NavigationLink("电脑只读接入") { DesktopBridgeView(bridge: desktop) }
                Button("批量导出录音、文字和回顾") { showExport = true }.disabled(clips.isEmpty)
                Toggle("小组件显示回顾标题", isOn: $widgetTitles).onChange(of: widgetTitles) { _, _ in updateWidget(force: true) }
                NavigationLink("组件与模型来源") { ThirdPartyNoticesView() }
            }
        }.navigationTitle("设置")
    }
    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) { Text(value).font(.title3.monospacedDigit()).bold(); Text(title).font(.caption).foregroundStyle(.secondary) }
    }
    private func refresh() {
        do { clips = try store.clips(); loadError = nil; intelligence.refresh(); updateWidget() }
        catch { loadError = error.localizedDescription }
    }
    private func updateWidget(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastWidgetUpdate) >= 5 * 60 else { return }
        lastWidgetUpdate = Date()
        let calendar = DailySchedule().calendar
        let today = clips.filter { calendar.isDateInToday($0.startedAt) }
        let title = widgetTitles ? intelligence.reviews.last(where: { calendar.isDateInToday($0.day) && $0.kind != .answer })?.title : nil
        WidgetSnapshotStore.save(DayTapeWidgetSnapshot(updatedAt: Date(), recordedSeconds: today.reduce(0) { $0 + $1.duration },
            clipCount: today.count, pendingCount: today.filter { store.cloudReceipt($0.id)?.matches($0) != true }.count,
            recordingState: archive.status, reviewTitle: title))
        WidgetCenter.shared.reloadAllTimelines()
    }
}

@MainActor
struct RecordingDetailView: View {
    let clip: Clip
    let store: ClipStore
    @ObservedObject var intelligence: IntelligenceController
    @ObservedObject var context: PhoneContextService
    @ObservedObject var voice: VoiceIdentityService
    @ObservedObject var archive: NightArchiveController
    @ObservedObject var playback: Playback
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false
    @State private var errorText: String?
    @State private var editing: TranscriptSegment?
    @State private var sharingAudio: AudioShare?
    @State private var preparingShare = false
    private struct AudioShare: Identifiable { let id = UUID(); let url: URL }
    private var document: TranscriptDocument? { intelligence.documents.first { $0.clipID == clip.id } }
    var body: some View {
        List {
            Section {
                Text(clip.startedAt.formatted(date: .complete, time: .standard)).font(.headline)
                Text("\(Int(clip.duration)) 秒").foregroundStyle(.secondary)
                if store.hasLocalAudio(clip.id) {
                    Button(playback.playingID == clip.id ? "停止回放" : "播放原声") { playback.toggle(clip, store: store) }
                    Button(preparingShare ? "正在准备…" : "导出原声") {
                        preparingShare = true
                        Task {
                            do { sharingAudio = AudioShare(url: try await ArchiveExport.audio(clip: clip, store: store)) }
                            catch { errorText = error.localizedDescription }
                            preparingShare = false
                        }
                    }.disabled(preparingShare)
                } else if let url = store.cloudReceipt(clip.id)?.viewURL {
                    Link("在 Google Drive 打开原声", destination: url)
                }
            }
            let marks = context.marks(for: clip)
            if !marks.isEmpty {
                Section("重要时刻") {
                    ForEach(marks) { mark in
                        Button { playback.play(clip, store: store, offset: mark.clipOffset ?? 0) } label: {
                            Label(mark.label + " · " + clock(mark.clipOffset ?? 0), systemImage: "bookmark.fill")
                        }.disabled(!store.hasLocalAudio(clip.id))
                    }
                }
            }
            Section("转写") {
                if let document = document {
                    if !document.isComplete { Text("已保存部分转写，可从检查点继续。").font(.caption).foregroundStyle(.secondary) }
                    ForEach(document.segments) { segment in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Button(clock(segment.offset)) { playback.play(clip, store: store, offset: segment.offset) }
                                    .font(.caption.monospacedDigit()).disabled(!store.hasLocalAudio(clip.id))
                                if let name = segment.speakerLabel { Text(name).font(.caption).foregroundStyle(.secondary) }
                            }
                            Text(segment.text).textSelection(.enabled)
                        }
                        .contextMenu { Button("修改文字与说话人") { editing = segment } }
                    }
                } else { Text("尚未转写").foregroundStyle(.secondary) }
                Button(intelligence.isProcessing ? "暂停转写" : "转写这一天") {
                    if intelligence.isProcessing { intelligence.pauseTranscription() } else { intelligence.startTranscription(day: clip.startedAt) }
                }
                if voice.enabled {
                    Button("识别这段的说话人") { voice.identify(clip: clip, intelligence: intelligence) }
                        .disabled(voice.isBusy || document?.isComplete != true || !store.hasLocalAudio(clip.id))
                    Text(voice.status).font(.caption).foregroundStyle(.secondary)
                    if let error = voice.errorText { Text(error).font(.caption).foregroundStyle(.orange) }
                }
            }
            if let place = context.location(for: clip), let coordinate = place.coordinate,
               let url = URL(string: "https://maps.apple.com/?ll=\(coordinate.latitude),\(coordinate.longitude)") {
                Section("大致地点") { Link("在地图查看 · 精度约 \(Int(coordinate.horizontalAccuracy)) 米", destination: url) }
            }
            if context.settings.healthEnabled {
                Section("同时间健康样本") {
                    if let snapshot = context.healthSnapshot(for: clip) {
                        if let value = snapshot.averageHeartRate { LabeledContent("平均心率", value: String(format: "%.0f 次/分钟", value)) }
                        if let value = snapshot.averageHRVSDNN { LabeledContent("HRV · SDNN", value: String(format: "%.1f 毫秒", value)) }
                        if let value = snapshot.stepCount { LabeledContent("步数", value: String(format: "%.0f", value)) }
                        if let value = snapshot.activeEnergyKilocalories { LabeledContent("活动能量", value: String(format: "%.1f 千卡", value)) }
                        if let value = snapshot.sleepMinutes { LabeledContent("睡眠重叠", value: String(format: "%.1f 分钟", value)) }
                    }
                    Button(context.refreshing ? "正在读取…" : "读取可用健康样本") { Task { await context.refresh(for: clip) } }.disabled(context.refreshing)
                }
            }
            if let error = errorText ?? playback.errorText ?? context.errorText { Section { Text(error).foregroundStyle(.orange) } }
            Section {
                Button("删除本机录音及相关文字", role: .destructive) { confirmDelete = true }
                    .disabled(intelligence.isProcessing || voice.isBusy || archive.activeCount > 0)
            }
        }
        .navigationTitle("录音详情")
        .confirmationDialog("删除这段本机录音和相关文字？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) { remove() }
        } message: { Text("Google Drive 中已经备份的文件会保留。") }
        .sheet(item: $editing) { segment in
            TranscriptEditView(segment: segment) { changed in
                guard var next = document, let index = next.segments.firstIndex(where: { $0.id == changed.id }) else { return }
                next.segments[index] = changed
                do { try intelligence.updateDocument(next) } catch { errorText = error.localizedDescription }
            }
        }
        .sheet(item: $sharingAudio) { item in
            AudioExport(url: item.url).onDisappear { ArchiveExport.discard(item.url) }
        }
    }
    private func clock(_ value: Double) -> String { String(format: "%02d:%02d", Int(value) / 60, Int(value) % 60) }
    private func remove() {
        playback.stop()
        do {
            try store.deleteByUser(clip)
            try intelligence.deleteContent(for: clip.id)
            try context.deleteContext(for: clip)
            dismiss()
        } catch { errorText = error.localizedDescription }
    }
}

private struct TranscriptEditView: View {
    @State var segment: TranscriptSegment
    let save: (TranscriptSegment) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("文字") { TextEditor(text: $segment.text).frame(minHeight: 160) }
                Section("说话人") { TextField("标签", text: Binding(get: { segment.speakerLabel ?? "" }, set: { segment.speakerLabel = $0.isEmpty ? nil : $0; segment.speakerID = nil })) }
            }.navigationTitle("修改转写")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("保存") { save(segment); dismiss() }.disabled(segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                }
        }
    }
}

@MainActor
struct VoiceIdentitySettingsView: View {
    @ObservedObject var service: VoiceIdentityService
    var body: some View {
        Form {
            Section("本机说话人识别") {
                Toggle("启用声音识别", isOn: $service.enabled)
                    .onChange(of: service.enabled) { _, value in
                        UserDefaults.standard.set(value, forKey: "daytape.voice.enabled")
                        if !value { service.pause() }
                    }
                Button(service.isBusy ? "正在准备…" : "下载并准备声音模型") { Task { await service.prepare() } }.disabled(service.isBusy || service.recording)
                Text("首次需联网下载本机模型；录音和声纹在本机处理。").font(.caption).foregroundStyle(.secondary)
                Text(service.status).font(.caption).foregroundStyle(.secondary)
                if let error = service.errorText { Text(error).foregroundStyle(.orange) }
            }
            Section("本人声纹") {
                if service.enrolled {
                    Label("本人声纹已保存在本机", systemImage: "checkmark.circle")
                    Button("删除本人声纹", role: .destructive) { Task { await service.removeProfile() } }.disabled(service.isBusy)
                } else {
                    Text("在安静处独自朗读，每段 15 秒，共三段。").font(.subheadline)
                    Button(service.recording ? "取消这次录制" : "录制第 \(min(3, service.samplesCollected + 1)) 段") {
                        if service.recording { service.cancelEnrollment() } else { Task { await service.recordEnrollment() } }
                    }.disabled(service.isBusy)
                }
                Text("声音标签是模型估计，可在转写中修正。").font(.caption).foregroundStyle(.secondary)
            }
        }.navigationTitle("声音识别")
        .onDisappear { service.cancelEnrollment() }
    }
}

struct ThirdPartyNoticesView: View {
    var body: some View {
        List {
            NavigationLink("声音模型来源与许可") { LicenseTextView(resource: "ModelAttribution") }
            NavigationLink("FluidAudio · Apache 2.0") { LicenseTextView(resource: "FluidAudio-APACHE-2.0") }
        }.navigationTitle("组件与模型来源")
    }
}

private struct LicenseTextView: View {
    let resource: String
    var body: some View {
        ScrollView {
            Text(Bundle.main.url(forResource: resource, withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "许可证资源未包含在此构建中。")
                .font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding()
        }.navigationTitle("来源与许可").navigationBarTitleDisplayMode(.inline)
    }
}

@MainActor
struct BulkExportView: View {
    let clips: [Clip]
    @ObservedObject var intelligence: IntelligenceController
    let store: ClipStore
    @Environment(\.dismiss) private var dismiss
    @State private var day = Date()
    @State private var allDays = false
    @State private var hour = -1
    @State private var options = ArchiveExport.Options()
    @State private var exporting = false
    @State private var exportTask: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase
    @State private var errorText: String?
    @State private var shared: ExportItem?
    private struct ExportItem: Identifiable { let id = UUID(); let url: URL }
    private var selected: [Clip] {
        let calendar = DailySchedule().calendar
        return clips.filter { clip in (allDays || calendar.isDate(clip.startedAt, inSameDayAs: day)) && (hour < 0 || calendar.component(.hour, from: clip.startedAt) == hour) }
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("范围") {
                    Toggle("全部日期", isOn: $allDays)
                    if !allDays { DatePicker("日期", selection: $day, displayedComponents: .date).environment(\.timeZone, DailySchedule().calendar.timeZone) }
                    Picker("小时", selection: $hour) {
                        Text("全天").tag(-1)
                        ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00–%02d:59", $0, $0)).tag($0) }
                    }
                    LabeledContent("选中录音", value: "\(selected.count) 段")
                }.disabled(exporting)
                Section("包含") {
                    Toggle("本机保留的原声", isOn: $options.audio)
                    Toggle("转写文字与时间戳", isOn: $options.transcripts)
                    Toggle("AI 回顾", isOn: $options.reviews)
                    Toggle("重要标记与可选关联", isOn: $options.context)
                }.disabled(exporting)
                if let error = errorText { Section { Text(error).foregroundStyle(.orange) } }
                Section {
                    Button(exporting ? "正在打包…" : "生成 ZIP 并分享") {
                        exporting = true; errorText = nil
                        exportTask = Task {
                            do { shared = ExportItem(url: try await ArchiveExport.make(clips: selected, intelligence: intelligence, store: store, options: options)) }
                            catch is CancellationError { errorText = "导出已暂停，请保持 App 在前台后重试。" }
                            catch { errorText = error.localizedDescription }
                            exporting = false
                            exportTask = nil
                        }
                    }.disabled(exporting || selected.isEmpty)
                }
            }.navigationTitle("批量导出")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() }.disabled(exporting) } }
                .sheet(item: $shared, onDismiss: { }) { item in
                    AudioExport(url: item.url).onDisappear { ArchiveExport.discard(item.url) }
                }
        }.interactiveDismissDisabled(exporting)
        .onChange(of: scenePhase) { _, phase in if phase != .active { exportTask?.cancel() } }
        .onDisappear { exportTask?.cancel() }
    }
}
