import Foundation
import AVFoundation
import Combine
import WatchKit
import UserNotifications
import WidgetKit

final class WatchRecorder: ObservableObject {
    enum Phase: Equatable { case idle, authorizing, recording, finishing, interrupted }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var recordedSeconds: Double = 0
    @Published private(set) var notice: String?
    @Published private(set) var routineStatus = "08:00 提醒 · 22:00 停止"
    @Published private(set) var markedCount = 0
    @Published private(set) var locationEnabled = false
    private let store: ClipStore
    private let transport: Connectivity
    private var engine: AVAudioEngine?
    private var writer: CaptureWriter?
    private var observers: [NSObjectProtocol] = []
    private var watchdog: Timer?
    private var lastAudio = Date()
    private var generation = UUID()
    private var wantsRecording = false
    private var tapInstalled = false
    private var stopDeadline: Date?
    private var stopTimer: Timer?
    private var pendingStartAt: Date?
    private var authorizationID: UUID?
    private var locationSampler: WatchLocationSampler?


    init(store: ClipStore, transport: Connectivity) {
        self.store = store; self.transport = transport; notice = store.recoveryMessage
        _ = DailyNotifications.shared
        DailyNotifications.shared.onError = { [weak self] error in self?.notice = error.localizedDescription }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .dailyStartRequested, object: nil, queue: .main) { [weak self] event in
            guard let self = self else { return }
            let now = Date()
            if let delivered = event.userInfo?["deliveredAt"] as? Date,
               let policy = try? self.store.dailySchedule(), policy.dayKey(delivered) != policy.dayKey(now) { return }
            self.pendingStartAt = event.userInfo?["requestedAt"] as? Date ?? now
            self.fulfillStartRequest()
        })
        observers.append(center.addObserver(forName: .recordingContextSettingsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.reloadContextSettings()
        })
        reloadContextSettings()
        consumeLaunchIntent()
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                            object: nil, queue: .main) { [weak self] event in self?.interruption(event) })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange,
                                            object: nil, queue: .main) { [weak self] _ in
            guard let self = self, self.phase == .recording else { return }
            self.stop(reason: "音频设备发生变化，请检查并重新开始。", interrupted: true)
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            self?.stop(reason: "系统音频服务已重启，请重新开始。", interrupted: true)
        })
    }
    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) }; watchdog?.invalidate(); stopTimer?.invalidate() }
    var busy: Bool { phase == .recording || phase == .authorizing || phase == .finishing }
    func requestForegroundStart() {
        pendingStartAt = Date()
        fulfillStartRequest()
    }
    func cancelPendingAuthorization() {
        guard phase == .authorizing else { return }
        authorizationID = nil; wantsRecording = false; pendingStartAt = nil
        UserDefaults.standard.removeObject(forKey: "daytape.pending.record.intent")
        phase = .idle; notice = "请回到手表前台，再点击开始录音。"
        publishWidget(reload: true)
    }
    private func consumeLaunchIntent() {
        guard let requested = UserDefaults.standard.object(forKey: "daytape.pending.record.intent") as? Date else { return }
        UserDefaults.standard.removeObject(forKey: "daytape.pending.record.intent")
        guard (0..<120).contains(Date().timeIntervalSince(requested)) else { return }
        pendingStartAt = requested
    }
    func markImportantMoment() {
        guard phase == .recording else { return }
        guard let position = writer?.positionSnapshot() else {
            notice = "音频正在准备，请稍后再标记。"; return
        }
        do {
            let context = try RecordingContextStore(root: store.root)
            try context.addMark(sessionID: generation, at: Date(), clipID: position.clipID, clipOffset: position.clipOffset)
            markedCount += 1
            WKInterfaceDevice.current().play(.click)
        } catch { notice = "标记未保存，请重试；录音仍在继续。" }
    }
    func setLocationEnabled(_ enabled: Bool) {
        do {
            var settings = try RecordingContextStore(root: store.root).settings()
            settings.locationEnabled = enabled
            try transport.configureContextSettings(settings)
            reloadContextSettings()
        } catch { notice = "位置设置未保存。" }
    }
    private func reloadContextSettings() {
        do {
            let context = try RecordingContextStore(root: store.root)
            locationEnabled = try context.settings().locationEnabled
            if !locationEnabled { locationSampler?.stop(); return }
            if locationSampler == nil {
                let sampler = WatchLocationSampler(context: context)
                sampler.onError = { [weak self] value in self?.notice = value }
                locationSampler = sampler
            }
            if phase == .recording { locationSampler?.start(sessionID: generation) }
        } catch { notice = "无法读取位置设置，继续仅录音。" }
    }
    private func publishWidget(reload: Bool) {
        let label: String
        switch phase {
        case .idle: label = "准备好了"
        case .authorizing: label = "正在准备麦克风"
        case .recording: label = "正在录音"
        case .finishing: label = "正在保存"
        case .interrupted: label = "录音已中断"
        }
        WidgetSnapshotStore.save(DayTapeWidgetSnapshot(recordedSeconds: recordedSeconds,
            clipCount: (try? store.clips().count) ?? 0, pendingCount: transport.pendingCount,
            recordingState: label))
        if reload { WidgetCenter.shared.reloadAllTimelines() }
    }
    func requestNotificationPermission() { configureRoutine() }
    func configureRoutine() {
        Task { @MainActor in
            do {
                let policy = try store.dailySchedule(); try store.saveDailySchedule(policy)
                try await DailyNotifications.shared.configure(policy, morningReminder: true)
                routineStatus = "08:00 提醒 · 22:00 停止"
            } catch { notice = error.localizedDescription }
        }
    }
    func restoreRoutine() {
        scheduleNightOpportunity()
        Task { @MainActor in
            do { try await DailyNotifications.shared.install(try store.dailySchedule(), morningReminder: true) }
            catch { notice = error.localizedDescription }
        }
    }
    private func scheduleNightOpportunity() {
        guard let policy = try? store.dailySchedule(), policy.enabled, policy.isValid else { return }
        var clock = DateComponents(); clock.hour = policy.stopHour; clock.minute = policy.stopMinute; clock.second = 0
        guard let next = policy.calendar.nextDate(after: Date(), matching: clock, matchingPolicy: .nextTime) else { return }
        // Opportunistic recovery if recording ended early. This is not a precise alarm or mic launch.
        WKApplication.shared().scheduleBackgroundRefresh(withPreferredDate: next, userInfo: NSString(string: "daytape.night")) { [weak self] error in
            if let error = error { self?.store.log("night-refresh-unavailable", detail: error.localizedDescription) }
        }
    }
    func fulfillStartRequest() {
        guard let requested = pendingStartAt, WKApplication.shared().applicationState == .active else { return }
        pendingStartAt = nil
        guard (0..<120).contains(Date().timeIntervalSince(requested)) else { notice = "请重新点击开始录音。"; return }
        start()
    }

    func start() {
        guard !busy else { return }
        do {
            let policy = try store.dailySchedule()
            let requestedAt = Date()
            guard policy.startAllowed(at: requestedAt) else { notice = "录音时间为达拉斯 08:00–22:00。"; return }
            stopDeadline = policy.stopDeadline(for: requestedAt)
            guard !policy.enabled || stopDeadline != nil else { notice = "停止时间无效，未开始录音。"; return }
            try store.sealDueDays()
        } catch { notice = error.localizedDescription; return }
        let requestID = UUID(); authorizationID = requestID
        wantsRecording = true; phase = .authorizing; notice = nil; publishWidget(reload: true)
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] allowed in
            DispatchQueue.main.async {
                guard let self = self, self.authorizationID == requestID,
                      self.wantsRecording, self.phase == .authorizing else { return }
                self.authorizationID = nil
                UserDefaults.standard.removeObject(forKey: "daytape.pending.record.intent")
                guard allowed else {
                    self.wantsRecording = false; self.phase = .idle
                    self.notice = "请在系统设置中允许麦克风访问。"; self.publishWidget(reload: true); return
                }
                guard WKApplication.shared().applicationState == .active else {
                    self.wantsRecording = false; self.phase = .interrupted
                    self.notice = "请在手表上打开应用并点击开始。"; self.publishWidget(reload: true); return
                }
                self.beginCapture()
            }
        }
    }
    private func beginCapture() {
        do {
            if let deadline = stopDeadline, Date() >= deadline { throw ArchiveError.invalidMetadata }
            try store.ensureBudget()
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement, options: [])
            // Public API, available since watchOS 6. Do not intentionally suppress the user's
            // system sounds/haptics during a long recording. Focus/notification settings still apply.
            do { try audioSession.setAllowHapticsAndSystemSoundsDuringRecording(true) }
            catch {
                notice = "系统暂未允许录音期间的声音或触感；录音会继续。"
                store.log("recording-system-haptics-unavailable", detail: error.localizedDescription)
            }
            try audioSession.setActive(true)
            let id = UUID(); generation = id; recordedSeconds = 0; markedCount = 0; lastAudio = Date()
            try store.beginCaptureMarker(sessionID: id, at: Date())
            let writer = CaptureWriter(store: store, sessionID: id, deadline: stopDeadline,
                onDeadline: { [weak self] in DispatchQueue.main.async {
                    guard let self = self, self.generation == id else { return }; self.scheduledStop()
                } }, onSealed: { [weak self] clip in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    do { try RecordingContextStore(root: self.store.root).resolveMarks(clips: [clip]) }
                    catch { self.notice = "标记位置稍后重试，录音已保存。" }
                    self.transport.clipSealed(); self.publishWidget(reload: false)
                }
            }, onFailure: { [weak self] error in
                DispatchQueue.main.async {
                    guard let self = self, self.generation == id else { return }
                    self.stop(reason: error.localizedDescription, interrupted: true)
                }
            }, onFrames: { [weak self] duration in
                DispatchQueue.main.async {
                    guard let self = self, self.generation == id, self.phase == .recording else { return }
                    self.recordedSeconds += duration; self.lastAudio = Date()
                }
            })
            self.writer = writer
            let engine = AVAudioEngine()
            self.engine = engine
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw ArchiveError.encoding }
            input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
                let beginning = Date().addingTimeInterval(-Double(buffer.frameLength) / buffer.format.sampleRate)
                writer.append(buffer, at: beginning)
            }
            tapInstalled = true
            engine.prepare(); try engine.start()
            phase = .recording
            reloadContextSettings(); publishWidget(reload: true)
            scheduleNightOpportunity()
            store.log("recording-start", detail: id.uuidString)
            watchdog?.invalidate()
            stopTimer?.invalidate()
            if let deadline = stopDeadline {
                let timer = Timer(fire: deadline, interval: 0, repeats: false) { [weak self] _ in self?.scheduledStop() }
                stopTimer = timer; RunLoop.main.add(timer, forMode: .common)
            }
            watchdog = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.reconcile() }
        } catch {
            wantsRecording = false
            if writer != nil { stop(reason: error.localizedDescription, interrupted: true) }
            else {
                try? store.finishCaptureMarker()
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                phase = .interrupted; notice = error.localizedDescription; alert(error.localizedDescription)
            }
        }
    }
    func stop(reason: String? = nil, interrupted: Bool = false) {
        guard phase == .recording || phase == .authorizing else { return }
        authorizationID = nil
        if !interrupted { wantsRecording = false }
        phase = .finishing; watchdog?.invalidate(); watchdog = nil
        locationSampler?.stop(); publishWidget(reload: true)
        stopTimer?.invalidate(); stopTimer = nil
        if let engine = engine {
            if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
            engine.stop()
        }
        tapInstalled = false
        engine = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        let finish: (Error?) -> Void = { [weak self] error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                var finalError = error
                if finalError == nil {
                    do { try self.store.finishCaptureMarker(); try self.store.sealDueDays() }
                    catch { finalError = error }
                }
                self.writer = nil; self.phase = interrupted || finalError != nil ? .interrupted : .idle
                self.notice = finalError?.localizedDescription ?? reason
                self.store.log(interrupted ? "recording-interrupted" : "recording-stop", detail: self.notice ?? "用户停止")
                if let text = self.notice, interrupted || finalError != nil { self.alert(text) }
                if reason == "scheduled-stop", finalError == nil {
                    self.notice = "今天录音已停止，等待传到手机并归档 Drive。"
                    DailyNotifications.shared.notify(id: "daytape.stopped", title: "今天的录音已停止",
                        body: "等待同步与备份。")
                }
                self.transport.pump(force: true)
                self.publishWidget(reload: true)
            }
        }
        if let writer = writer { writer.finish(finish) } else { finish(nil) }
    }
    private func scheduledStop() {
        guard phase == .recording || phase == .authorizing else { return }
        stop(reason: "scheduled-stop")
    }
    func reconcile() {
        consumeLaunchIntent()
        fulfillStartRequest()
        if phase != .recording {
            if !busy { do { try store.sealDueDays() } catch { notice = error.localizedDescription } }
            return
        }
        if let deadline = stopDeadline, Date() >= deadline { scheduledStop(); return }
        if engine?.isRunning != true || Date().timeIntervalSince(lastAudio) > 30 {
            stop(reason: "没有收到音频，录音已停止。请在手表上重新开始。", interrupted: true)
        }
    }
    private func interruption(_ event: Notification) {
        guard let raw = event.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .began {
            stop(reason: "系统正在使用麦克风，录音已中断。", interrupted: true)
        } else {
            let rawOptions = event.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let mayResume = AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
            if mayResume && wantsRecording && phase == .interrupted && WKApplication.shared().applicationState == .active {
                start()
            }
            // Do not start a new background microphone session or hide a recording gap.
        }
    }
    private func alert(_ text: String) {
        WKInterfaceDevice.current().play(.failure)
        let content = UNMutableNotificationContent()
        content.title = "DayTape 录音已停止"; content.body = text; content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "recording-stopped", content: content, trigger: nil))
    }
}
