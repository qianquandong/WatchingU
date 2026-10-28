import Foundation
import Combine
import WatchConnectivity
#if os(watchOS)
import WatchKit
#endif

final class Connectivity: NSObject, ObservableObject, WCSessionDelegate {
    @Published private(set) var status = "正在连接"
    @Published private(set) var pendingCount = 0
    @Published private(set) var pendingBytes: UInt64 = 0
    @Published private(set) var errorText: String?
    let store: ClipStore
    private let session: WCSession
    private var retryTimer: Timer?
    private var batch = WatchTransferBatch()
    private let encoder = JSONEncoder()

    init(store: ClipStore) {
        self.store = store; session = .default
        super.init()
        guard WCSession.isSupported() else { status = "设备不支持配对传输"; return }
        session.delegate = self
        session.activate()
        #if os(watchOS)
        WKInterfaceDevice.current().isBatteryMonitoringEnabled = true
        #endif
        retryTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            self?.pump()
        }
        refresh()
    }
    deinit { retryTimer?.invalidate() }
    func report(_ error: Error) {
        DispatchQueue.main.async { self.errorText = error.localizedDescription }
        store.log("transfer-error", detail: error.localizedDescription)
    }
    func refresh() {
        #if os(watchOS)
        do {
            let pending = try store.pending()
            pendingCount = pending.count
            pendingBytes = pending.reduce(0) { $0 + $1.byteCount }
        } catch { report(error) }
        #endif
        if session.activationState == .activated {
            #if os(iOS)
            guard session.isPaired else { status = "请先在 iPhone 配对 Apple Watch"; return }
            guard session.isWatchAppInstalled else { status = "请先在 Apple Watch 安装 DayTape"; return }
            #elseif os(watchOS)
            guard session.isCompanionAppInstalled else { status = "请先在 iPhone 安装 DayTape"; return }
            #endif
            status = session.isReachable ? "配对设备可达" : "已配对 · 等待系统传输"
        } else { status = "传输会话未就绪" }
    }
    /// Open a bounded batch about every 15 minutes and drain that snapshot as receipts arrive.
    /// System scheduling may delay delivery; a batch never continually absorbs newly recorded clips.
    func pump(force: Bool = false, manualOverride: Bool = false) {
        refresh()
        #if os(watchOS)
        guard session.activationState == .activated else { return }
        guard session.isCompanionAppInstalled else { status = "请先在 iPhone 安装 DayTape"; return }
        let now = Date()
        let device = WKInterfaceDevice.current()
        let connectedToPower = device.batteryState == .charging || device.batteryState == .full
        let lowBattery = device.batteryLevel >= 0 && device.batteryLevel < 0.2 && !connectedToPower
        guard batch.prepare(at: now, force: force, manualOverride: manualOverride,
                            batteryLevel: device.batteryLevel, charging: connectedToPower) else {
            status = lowBattery ? "电量较低 · 录音继续，稍后同步" : "录音已保存 · 等待下一批同步"
            scheduleTransferOpportunity(); return
        }
        do {
            try store.sealDueDays(now: now)
        } catch { report(error); return }
        guard let cutoff = batch.cutoff else { return }
        do {
            let context = try RecordingContextStore(root: store.root)
            let contextPending = try context.pending().filter { $0.1.recordedAt <= cutoff }
            let audioPending = try store.pending().filter { $0.startedAt.addingTimeInterval($0.duration) <= cutoff }
            let outstanding = session.outstandingFileTransfers
            let inFlight = Set(outstanding.compactMap { $0.file.metadata?["clipID"] as? String })
            let contextInFlight = Set(outstanding.compactMap { $0.file.metadata?["contextID"] as? String })
            var slots = max(0, 3 - outstanding.count)
            var sent = false
            let sealsInFlight = Set(outstanding.compactMap { $0.file.metadata?["dayKey"] as? String })
            for (url, closure) in try store.dayClosures() where slots > 0 && !store.isDayConfirmed(closure) {
                guard !sealsInFlight.contains(closure.dayKey) else { continue }
                let proof = try store.hash(url)
                session.transferFile(url, metadata: ["kind":"day-closure", "dayKey":closure.dayKey,
                    "sha256":proof.1, "bytes":NSNumber(value: proof.0)])
                slots -= 1; sent = true
            }
            for (url, packet, bytes, digest) in contextPending where slots > 0 {
                guard !contextInFlight.contains(packet.id.uuidString), context.mayEnqueue(packet.id, at: now) else { continue }
                try context.noteEnqueued(packet.id, at: now)
                session.transferFile(url, metadata: ["kind":"recording-context", "contextID":packet.id.uuidString,
                    "sha256":digest, "bytes":NSNumber(value: bytes)])
                slots -= 1; sent = true
            }
            for var clip in audioPending where slots > 0 {
                let eligible = rr_should_enqueue(0, inFlight.contains(clip.id.uuidString) ? 1 : 0,
                                                 now.timeIntervalSince1970, clip.retryAfter.timeIntervalSince1970)
                guard eligible != 0 else { continue }
                guard FileManager.default.fileExists(atPath: store.audioURL(clip.id).path) else {
                    throw ArchiveError.invalidMetadata
                }
                let data = try encoder.encode(clip)
                let delay = rr_retry_delay(clip.attempts)
                clip.attempts = min(clip.attempts, 1000) + 1
                clip.retryAfter = now.addingTimeInterval(max(120, delay))
                try store.update(clip)
                session.transferFile(store.audioURL(clip.id), metadata: ["kind": "clip", "clipID": clip.id.uuidString, "manifest": data])
                slots -= 1; sent = true
            }
            batch.finishIfDrained(audioPending: !audioPending.isEmpty, contextPending: !contextPending.isEmpty)
            if sent { status = "正在批量同步到手机" }
            scheduleTransferOpportunity()
        } catch { report(error) }
        refresh()
        #endif
    }
    func clipSealed() { pump() }
    #if os(watchOS)
    private func scheduleTransferOpportunity() {
        WKApplication.shared().scheduleBackgroundRefresh(withPreferredDate: Date().addingTimeInterval(15 * 60),
            userInfo: NSString(string: "daytape.transfer")) { _ in }
    }
    #endif
    func configureContextSettings(_ value: RecordingContextSettings) throws {
        try RecordingContextStore(root: store.root).saveSettings(value)
        #if os(watchOS)
        UserDefaults.standard.set(value.locationEnabled, forKey: "daytape.location.preference.pending")
        sendPendingContextPreference()
        #else
        try configureRoutine(try store.dailySchedule())
        #endif
        NotificationCenter.default.post(name: .recordingContextSettingsChanged, object: nil)
    }
    #if os(watchOS)
    private func sendPendingContextPreference() {
        guard session.activationState == .activated,
              let enabled = UserDefaults.standard.object(forKey: "daytape.location.preference.pending") as? Bool else { return }
        session.transferUserInfo(["kind":"context-settings", "locationEnabled":enabled])
        UserDefaults.standard.removeObject(forKey: "daytape.location.preference.pending")
    }
    #endif
    func configureRoutine(_ value: DailySchedule) throws {
        try store.saveDailySchedule(value)
        if session.activationState == .activated {
            #if os(iOS)
            guard session.isPaired, session.isWatchAppInstalled else { refresh(); return }
            #elseif os(watchOS)
            guard session.isCompanionAppInstalled else { refresh(); return }
            #endif
            let context = try RecordingContextStore(root: store.root).settings()
            try session.updateApplicationContext(["dailyPlan":try JSONEncoder().encode(value),
                                                   "contextSettings":try JSONEncoder().encode(context)])
        }
    }
    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String:Any]) {
        #if os(watchOS)
        do {
            if let data = applicationContext["dailyPlan"] as? Data, data.count < 4096 {
                let value = try JSONDecoder().decode(DailySchedule.self, from: data)
                try store.saveDailySchedule(value)
                Task { try? await DailyNotifications.shared.install(value, morningReminder: true) }
            }
            if let data = applicationContext["contextSettings"] as? Data, data.count < 4096 {
                try RecordingContextStore(root: store.root).saveSettings(JSONDecoder().decode(RecordingContextSettings.self, from: data))
                DispatchQueue.main.async { NotificationCenter.default.post(name: .recordingContextSettingsChanged, object: nil) }
            }
        } catch { report(error) }
        #endif
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            if let error = error { self.report(error) }
            #if os(iOS)
            do { try self.configureRoutine(try self.store.dailySchedule()) } catch { self.report(error) }
            #elseif os(watchOS)
            self.sendPendingContextPreference()
            #endif
            self.pump(force: true)
        }
    }
    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async { self.pump(force: true) }
    }
    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        #if os(iOS)
        do {
            if file.metadata?["kind"] as? String == "recording-context" {
                guard let rawID = file.metadata?["contextID"] as? String, let id = UUID(uuidString: rawID),
                      let digest = file.metadata?["sha256"] as? String,
                      let bytes = file.metadata?["bytes"] as? NSNumber else { throw ArchiveError.invalidMetadata }
                let context = try RecordingContextStore(root: store.root)
                let receipt = try context.receive(file.fileURL, id: id, expectedBytes: bytes.uint64Value, expectedHash: digest)
                try context.resolveMarks(clips: store.clips())
                session.transferUserInfo(["kind":"context-receipt", "receipt":try JSONEncoder().encode(receipt)])
                DispatchQueue.main.async { NotificationCenter.default.post(name: .recordingContextChanged, object: nil) }
                return
            }
            if file.metadata?["kind"] as? String == "day-closure" {
                guard let digest = file.metadata?["sha256"] as? String,
                      let bytes = file.metadata?["bytes"] as? NSNumber else { throw ArchiveError.invalidMetadata }
                try store.receiveDayClosure(file.fileURL, expectedHash: digest, expectedBytes: bytes.uint64Value)
                let value = try JSONDecoder().decode(DayClosure.self, from: Data(contentsOf: file.fileURL))
                session.transferUserInfo(["kind":"day-receipt", "dayKey":value.dayKey,"revision":value.revision])
                DispatchQueue.main.async { NotificationCenter.default.post(name: .archiveChanged, object: nil) }
                return
            }
            guard file.metadata?["kind"] as? String == "clip",
                  let data = file.metadata?["manifest"] as? Data, data.count < 32768 else {
                throw ArchiveError.invalidMetadata
            }
            let clip = try JSONDecoder().decode(Clip.self, from: data)
            guard file.metadata?["clipID"] as? String == clip.id.uuidString else { throw ArchiveError.invalidMetadata }
            // This must complete before the delegate callback returns. Do not dispatch the inbox URL.
            let receipt = try store.receive(file.fileURL, clip: clip)
            try RecordingContextStore(root: store.root).resolveMarks(clips: [clip])
            let encoded = try JSONEncoder().encode(receipt)
            session.transferUserInfo(["kind": "receipt", "receipt": encoded])
            DispatchQueue.main.async {
                self.errorText = nil
                NotificationCenter.default.post(name: .archiveChanged, object: nil)
            }
        } catch { report(error) }
        #endif
    }
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        #if os(iOS)
        if userInfo["kind"] as? String == "context-settings", let enabled = userInfo["locationEnabled"] as? Bool {
            do {
                let context = try RecordingContextStore(root: store.root)
                var value = try context.settings(); value.locationEnabled = enabled
                try context.saveSettings(value)
                DispatchQueue.main.async {
                    do { try self.configureRoutine(self.store.dailySchedule()) } catch { self.report(error) }
                    NotificationCenter.default.post(name: .recordingContextSettingsChanged, object: nil)
                }
            } catch { report(error) }
            return
        }
        #endif
        #if os(watchOS)
        do {
            if userInfo["kind"] as? String == "context-receipt", let data = userInfo["receipt"] as? Data, data.count < 4096 {
                try RecordingContextStore(root: store.root).acknowledge(JSONDecoder().decode(ContextReceipt.self, from: data))
                DispatchQueue.main.async { self.pump() }; return
            }
            if userInfo["kind"] as? String == "day-receipt", let key = userInfo["dayKey"] as? String,
               let revision = userInfo["revision"] as? String {
                try store.acknowledgeDay(key, revision: revision)
                DispatchQueue.main.async { self.pump() }; return
            }
            guard userInfo["kind"] as? String == "receipt",
                  let data = userInfo["receipt"] as? Data, data.count < 4096 else { return }
            let receipt = try JSONDecoder().decode(Receipt.self, from: data)
            try store.acknowledge(receipt)
            DispatchQueue.main.async { self.errorText = nil; self.pump() }
        } catch { report(error) }
        #endif
    }
    func session(_ session: WCSession, fileTransfer: WCSessionFileTransfer, didFinishWithError error: Error?) {
        // Transport success is never a persistence acknowledgement. Keep the audio until receipt.
        DispatchQueue.main.async {
            if let error = error { self.report(error) }
            self.pump()
        }
    }
    #if os(iOS)
    func sessionWatchStateDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            do { try self.configureRoutine(try self.store.dailySchedule()) } catch { self.report(error) }
            self.refresh()
        }
    }
    func sessionDidBecomeInactive(_ session: WCSession) {
        DispatchQueue.main.async { self.refresh() }
    }
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    #endif
}
