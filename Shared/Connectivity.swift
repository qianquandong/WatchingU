import Foundation
import Combine
import WatchConnectivity

final class Connectivity: NSObject, ObservableObject, WCSessionDelegate {
    @Published private(set) var status = "正在连接"
    @Published private(set) var pendingCount = 0
    @Published private(set) var pendingBytes: UInt64 = 0
    @Published private(set) var errorText: String?
    let store: ClipStore
    private let session: WCSession
    private var retryTimer: Timer?
    private var lastBatch = Date.distantPast
    private let encoder = JSONEncoder()

    init(store: ClipStore) {
        self.store = store; session = .default
        super.init()
        guard WCSession.isSupported() else { status = "设备不支持配对传输"; return }
        session.delegate = self
        session.activate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
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
            status = session.isReachable ? "配对设备可达" : "已配对 · 等待系统传输"
        } else { status = "传输会话未就绪" }
    }
    /// A five-minute batch window limits radio activity. Timers are not a background execution guarantee;
    /// activation, foreground entry, each sealed clip and completion also trigger this method.
    func pump(force: Bool = false, manualOverride: Bool = false) {
        refresh()
        #if os(watchOS)
        guard session.activationState == .activated else { return }
        guard session.isCompanionAppInstalled else { status = "请先在 iPhone 安装 DayTape"; return }
        let now = Date()
        do {
            let policy = try store.dailySchedule()
            guard manualOverride || policy.transferWindow(at: now) else { status = "白天本地录音 · 22:00 后批量同步"; return }
            try store.sealDueDays(now: now)
        } catch { report(error); return }
        guard force || now.timeIntervalSince(lastBatch) >= 300 else { return }
        do {
            let outstanding = session.outstandingFileTransfers
            let inFlight = Set(outstanding.compactMap { $0.file.metadata?["clipID"] as? String })
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
            for var clip in try store.pending() where slots > 0 {
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
            if sent { lastBatch = now }
        } catch { report(error) }
        refresh()
        #endif
    }
    func clipSealed() { pump() }
    func configureRoutine(_ value: DailySchedule) throws {
        try store.saveDailySchedule(value)
        if session.activationState == .activated {
            try session.updateApplicationContext(["dailyPlan":try JSONEncoder().encode(value)])
        }
    }
    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String:Any]) {
        #if os(watchOS)
        guard let data = applicationContext["dailyPlan"] as? Data, data.count < 4096 else { return }
        do {
            let value = try JSONDecoder().decode(DailySchedule.self, from: data)
            try store.saveDailySchedule(value)
            Task { try? await DailyNotifications.shared.install(value, morningReminder: true) }
        } catch { report(error) }
        #endif
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            if let error = error { self.report(error) }
            #if os(iOS)
            do { try self.configureRoutine(try self.store.dailySchedule()) } catch { self.report(error) }
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
        #if os(watchOS)
        do {
            if userInfo["kind"] as? String == "day-receipt", let key = userInfo["dayKey"] as? String,
               let revision = userInfo["revision"] as? String {
                try store.acknowledgeDay(key, revision: revision)
                DispatchQueue.main.async { self.pump(force: true) }; return
            }
            guard userInfo["kind"] as? String == "receipt",
                  let data = userInfo["receipt"] as? Data, data.count < 4096 else { return }
            let receipt = try JSONDecoder().decode(Receipt.self, from: data)
            try store.acknowledge(receipt)
            DispatchQueue.main.async { self.errorText = nil; self.pump(force: true) }
        } catch { report(error) }
        #endif
    }
    func session(_ session: WCSession, fileTransfer: WCSessionFileTransfer, didFinishWithError error: Error?) {
        // Transport success is never a persistence acknowledgement. Keep the audio until receipt.
        DispatchQueue.main.async {
            if let error = error { self.report(error) }
            self.pump(force: true)
        }
    }
    #if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {
        DispatchQueue.main.async { self.refresh() }
    }
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    #endif
}
