import Foundation
import Combine
import UIKit
import BackgroundTasks
import Network

@MainActor
final class NightArchiveController: NSObject, ObservableObject, URLSessionTaskDelegate {
    // Retained only to cancel and drain the old OS-owned upload session.
    static var backgroundID: String { (Bundle.main.bundleIdentifier ?? "com.aimanjack.daytape") + ".drive-upload" }
    static var processingID: String { (Bundle.main.bundleIdentifier ?? "com.aimanjack.daytape") + ".nightarchive" }
    @Published private(set) var settings: ArchiveSettings
    @Published private(set) var status = "自动备份尚未启用"
    @Published private(set) var errorText: String?
    @Published private(set) var cloudCount = 0
    @Published private(set) var localCount = 0
    @Published private(set) var activeCount = 0
    @Published private(set) var latestCompleteDay: String?
    @Published private(set) var routine = DailySchedule()
    @Published private(set) var connectingBackup = false
    @Published private(set) var backupSetupError: String?
    @Published private(set) var notificationHint: String?
    @Published private(set) var connectedToPower = false
    var uploadClock: BackupClock { settings.resolvedUploadClock(for: routine) } // Old settings remain readable.
    var onProcessingOpportunity: ((Bool) -> Void)?
    var processDuringBackgroundOpportunity: (() async -> Void)? { didSet { schedule() } }
    let connection = DriveConnection()
    let sleep = SleepMonitor()
    private let store: ClipStore
    private let journal: ArchiveJournal
    private let reminder: BackupReminder
    private let network: URLSession
    private lazy var api: DriveAPI = {
        let value = DriveAPI(connection: connection, session: network)
        value.prepareRequest = { [weak self] request in
            guard let self = self else { throw CancellationError() }
            try self.checkRequestPermission(); self.configureNetwork(&request)
        }
        return value
    }()
    private var jobs: [UUID: ArchiveJob] = [:]
    private var work: Task<Void, Never>?
    private var needsPass = false
    private var currentIsManual = false
    private var manualThrough: Date?
    private var manualBatchID: UUID?
    private var wifiAvailable = false
    private var foregroundAvailable = false
    private var backgroundWindow = false
    private var backgroundRunID: UUID?
    private var backgroundRunner: Task<Void, Never>?
    private var registered = false
    private var scheduled = false
    private var didMigrateLegacyTasks = false
    private var legacyTaskIDs: Set<Int> = []
    private var legacyCompletion: (() -> Void)?
    private var legacyEventsFinished = false
    private var observers: [NSObjectProtocol] = []
    private let monitor = NWPathMonitor()
    private lazy var legacyUploads: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.backgroundID)
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    init(store: ClipStore) throws {
        let disk = try ArchiveJournal(store: store)
        self.store = store; journal = disk; settings = try disk.settings()
        reminder = BackupReminder(directory: disk.root)
        routine = try store.dailySchedule()
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false; config.httpMaximumConnectionsPerHost = 2
        config.timeoutIntervalForRequest = 45; config.timeoutIntervalForResource = 180
        network = URLSession(configuration: config)
        super.init()
        _ = DailyNotifications.shared
        for job in try disk.jobs() { jobs[job.clipID] = job }
        UIDevice.current.isBatteryMonitoringEnabled = true
        foregroundAvailable = UIApplication.shared.applicationState == .active
        updatePower()
        observe(.archiveChanged) { $0.requestPump() }
        observe(UIDevice.batteryStateDidChangeNotification) { value in
            value.updatePower()
            if !value.connectedToPower && value.backgroundWindow {
                value.backgroundWindow = false
                value.onProcessingOpportunity?(false)
                value.work?.cancel(); value.backgroundRunner?.cancel()
            }
            if !value.connectedToPower && !value.currentIsManual { value.work?.cancel() }
            value.requestPump()
        }
        observe(UIApplication.didBecomeActiveNotification) { value in
            value.foregroundAvailable = true; value.updatePower(); value.requestPump()
        }
        observe(UIApplication.willResignActiveNotification) { value in
            value.foregroundAvailable = false
            if !value.backgroundWindow {
                // An explicit manual batch never becomes a silent future battery exception.
                value.manualThrough = nil; value.manualBatchID = nil; value.work?.cancel()
            }
        }
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied && (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet))
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.wifiAvailable = available
                if self.settings.wifiOnly && !available { self.work?.cancel() }
                self.requestPump()
            }
        }
        monitor.start(queue: DispatchQueue(label: "daytape.network"))
        // A cancelled legacy request may already have reached Drive. Stable IDs and hashes
        // are reconciled before new upload sessions; cancellation is not proof of failure.
        migrateLegacyTasks()
        refreshCounts()
    }
    deinit {
        monitor.cancel(); work?.cancel(); backgroundRunner?.cancel()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        network.invalidateAndCancel()
    }
    private func observe(_ name: Notification.Name, action: @escaping (NightArchiveController) -> Void) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in guard let self = self else { return }; action(self) }
        })
    }
    private var power: BackupPowerState {
        switch UIDevice.current.batteryState {
        case .charging: return .charging
        case .full: return .full
        case .unplugged: return .unplugged
        default: return .unknown
        }
    }
    private func updatePower() { connectedToPower = power.connectedToPower }
    private var runtimeAvailable: Bool { foregroundAvailable || backgroundWindow }
    private func allowed(manual: Bool) -> Bool {
        ChargingBackupPolicy.allowsRequest(enabled: settings.enabled, power: power,
            wifiOnly: settings.wifiOnly, wifiAvailable: wifiAvailable,
            runtimeAvailable: runtimeAvailable, manualBatch: manual)
    }
    private func checkRequestPermission() throws {
        try Task.checkCancellation()
        guard allowed(manual: currentIsManual) else { throw CancellationError() }
    }
    private func configureNetwork(_ request: inout URLRequest) {
        request.allowsCellularAccess = !settings.wifiOnly
        request.allowsExpensiveNetworkAccess = !settings.wifiOnly
        request.allowsConstrainedNetworkAccess = !settings.wifiOnly
    }
    private func waitingStatus() -> String {
        if !settings.enabled { return "自动备份尚未启用" }
        if settings.wifiOnly && !wifiAvailable { return "等待 Wi-Fi · 本地录音保留" }
        if manualThrough == nil && !power.connectedToPower { return "等待 iPhone 充电 · 本地录音保留" }
        if !runtimeAvailable { return "等待系统后台机会 · 本地录音保留" }
        return "等待重试 · 本地录音保留"
    }
    func report(_ error: Error) { errorText = error.localizedDescription; status = "等待重试 · 本地录音保留" }
    func change(_ body: (inout ArchiveSettings) -> Void) {
        do {
            var next = settings; body(&next); try journal.save(next)
            let restricted = next.wifiOnly && !settings.wifiOnly
            settings = next
            if !settings.enabled || restricted { manualThrough = nil; manualBatchID = nil; work?.cancel() }
            if !settings.useSleepRecords { sleep.stop() }
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.processingID); scheduled = false
            schedule(); requestPump()
        } catch { report(error) }
    }
    func enable(_ enabled: Bool) async {
        if !enabled { change { $0.enabled = false }; return }
        do {
            _ = try await connection.access()
            change { $0.enabled = true; $0.useSleepRecords = false; $0.fallbackEnabled = false }
            await wake()
        } catch { report(error) }
    }
    func beginBackupSetup() { backupSetupError = nil }
    func connectBackupAccount() async -> Bool {
        guard !connectingBackup else { return false }
        guard activeCount == 0 else { backupSetupError = "请先停止当前备份，再连接其他账户。"; return false }
        connectingBackup = true; backupSetupError = nil
        defer { connectingBackup = false }
        do { try await connection.connect(); errorText = nil; return true }
        catch {
            backupSetupError = connection.configured ? "Google Drive 尚未连接。你可以重试，也可以暂时只保存在手机。" : CloudArchiveError.setupRequired.localizedDescription
            return false
        }
    }
    /// The old clock argument remains decodable, but automatic uploads are now power-triggered.
    func saveAutomaticBackup(clock: BackupClock = BackupClock(), wifiOnly: Bool, keepOneDay: Bool) async -> Bool {
        backupSetupError = nil
        do {
            _ = try await connection.access()
            var next = settings
            next.enabled = true; next.useSleepRecords = false; next.fallbackEnabled = false
            next.uploadClock = clock; next.wifiOnly = wifiOnly; next.purgeAfterVerification = keepOneDay
            try journal.save(next)
            settings = next; errorText = nil; manualThrough = nil; manualBatchID = nil; sleep.stop(); work?.cancel()
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.processingID); scheduled = false
            schedule(); requestPump(); return true
        } catch {
            backupSetupError = "没有保存这次更改。原来的设置会保留，请检查连接后重试。"; return false
        }
    }
    func restoreBackupConnection() async {
        guard settings.enabled else { return }
        do { _ = try await connection.access(); requestPump() }
        catch { status = "暂时无法确认 Google Drive 连接 · 本地录音保留" }
    }
    func disconnect() {
        guard activeCount == 0 else { status = "请先停止当前备份。"; return }
        change { $0.enabled = false }; connection.signOut()
    }
    func configureRoutine() async {
        notificationHint = nil
        do {
            try store.saveDailySchedule(routine)
            try await DailyNotifications.shared.configure(routine, morningReminder: false)
            await updateReminder()
        } catch { notificationHint = "通知未开启" }
    }
    func archiveNow() {
        guard settings.enabled else { status = "请先启用自动备份。"; return }
        manualThrough = Date(); manualBatchID = UUID(); work?.cancel(); requestPump()
    }
    func cancelCurrentBackup() {
        manualThrough = nil; manualBatchID = nil; needsPass = false; work?.cancel()
        status = "备份已暂停 · 本地录音保留"
    }
    func sleepEvidence(_ end: Date) {
        guard end <= Date() else { return }
        change { $0.lastSleepEvidence = end } // Never bypass power or network gates.
    }
    func wake() async {
        updatePower(); schedule(); requestPump()
        while let running = work { await running.value }
    }
    func requestPump() {
        guard work == nil else { needsPass = true; return }
        work = Task { @MainActor [weak self] in
            guard let self = self else { return }
            await self.pump(); self.work = nil
            if self.needsPass { self.needsPass = false; self.requestPump() }
        }
    }
    private func refreshCounts() {
        guard let clips = try? store.clips() else { return }
        localCount = clips.filter { store.hasLocalAudio($0.id) }.count
        cloudCount = clips.filter { store.cloudReceipt($0.id)?.matches($0) == true }.count
    }
    private func updateReminder() async {
        do {
            let oldest = try store.clips().first { clip in
                guard store.hasLocalAudio(clip.id) else { return false }
                guard let receipt = store.cloudReceipt(clip.id), receipt.matches(clip) else { return true }
                return connection.accountID.map { $0 != receipt.accountID } ?? false
            }
            try await reminder.update(oldest: oldest, enabled: settings.enabled)
        } catch { notificationHint = "备份提醒暂未设置成功" }
    }
    private func pump() async {
        let explicitBatch = manualBatchID
        defer {
            if manualBatchID == explicitBatch { manualThrough = nil; manualBatchID = nil }
            activeCount = 0; currentIsManual = false; refreshCounts(); schedule()
        }
        await updateReminder()
        guard didMigrateLegacyTasks else { return }
        guard allowed(manual: manualThrough != nil) else { status = waitingStatus(); return }
        currentIsManual = manualThrough != nil
        activeCount = 1
        do {
            let auth = try await connection.access(); try checkRequestPermission()
            for clip in try store.clips() {
                try Task.checkCancellation()
                currentIsManual = ChargingBackupPolicy.manualBatchContains(
                    clipEnd: clip.startedAt.addingTimeInterval(clip.duration), requestedThrough: manualThrough)
                guard allowed(manual: currentIsManual) else {
                    if manualThrough != nil { continue }
                    status = waitingStatus(); return
                }
                guard store.hasLocalAudio(clip.id) else { continue }
                if let proof = store.cloudReceipt(clip.id), proof.accountID == auth.account, proof.matches(clip) { continue }
                guard currentIsManual || Date() >= (jobs[clip.id]?.retryAfter ?? .distantPast) else { continue }
                activeCount = 1; status = "正在备份录音"
                do {
                    guard store.retainAudio(clip.id) else { continue }
                    defer { store.releaseAudio(clip.id) }
                    var job: ArchiveJob
                    if let existing = jobs[clip.id] { job = existing }
                    else { job = try await makeJob(clip, account: auth.account); jobs[clip.id] = job; try journal.save(job) }
                    guard job.accountID == auth.account else { throw CloudArchiveError.accountChanged }
                    for kind in ["audio", "metadata"] {
                        try checkRequestPermission()
                        var item = kind == "audio" ? job.audio : job.metadata
                        // Re-read stable IDs even after a lost HTTP response or a legacy cancellation.
                        if let remote = try await api.file(item.fileID, account: job.accountID) {
                            guard remote.verifies(item) else { throw CloudArchiveError.remoteMismatch }
                            item.phase = .verified; item.sessionURL = nil
                        } else {
                            let path = kind == "audio" ? store.audioURL(clip.id) : journal.payloadURL(clip.id)
                            let pair = try store.hash(path)
                            guard pair.0 == item.byteCount, pair.1 == item.sha256 else { throw CloudArchiveError.remoteMismatch }
                            item.sessionURL = try await api.begin(item, job: job); item.phase = .transferring
                            if kind == "audio" { job.audio = item } else { job.metadata = item }
                            jobs[clip.id] = job; try journal.save(job)
                            let token = try await connection.access(expectedAccount: job.accountID)
                            try checkRequestPermission()
                            var request = URLRequest(url: item.sessionURL!); request.httpMethod = "PUT"
                            request.setValue("Bearer \(token.token)", forHTTPHeaderField: "Authorization")
                            request.setValue(item.mimeType, forHTTPHeaderField: "Content-Type")
                            request.setValue(String(item.byteCount), forHTTPHeaderField: "Content-Length")
                            configureNetwork(&request)
                            let (_, response) = try await network.upload(for: request, fromFile: path)
                            try checkRequestPermission()
                            guard let http = response as? HTTPURLResponse else { throw CloudArchiveError.invalidResponse }
                            guard (200..<300).contains(http.statusCode) else { throw CloudArchiveError.http(http.statusCode) }
                            item.phase = .needsVerification; item.sessionURL = nil
                            if kind == "audio" { job.audio = item } else { job.metadata = item }
                            jobs[clip.id] = job; try journal.save(job)
                            guard let remote = try await api.file(item.fileID, account: job.accountID), remote.verifies(item) else { throw CloudArchiveError.remoteMismatch }
                            item.phase = .verified
                        }
                        if kind == "audio" { job.audio = item } else { job.metadata = item }
                        jobs[clip.id] = job; try journal.save(job)
                    }
                    if job.complete { try await finalize(job, clip: clip) }
                } catch {
                    if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                    fail(clip.id, error: error)
                }
                activeCount = 0
            }
            try await reconcileDays(account: auth.account)
            await updateReminder()
            if errorText == nil { status = "本轮备份检查完成" }
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { status = waitingStatus() }
            else { report(error) }
        }
    }
    private func makeJob(_ clip: Clip, account: String) async throws -> ArchiveJob {
        let pair = try store.hash(store.audioURL(clip.id))
        guard pair.0 == clip.byteCount, pair.1 == clip.sha256 else { throw CloudArchiveError.remoteMismatch }
        let day = routine.dayKey(clip.startedAt)
        let folder = try await api.folder(day: day, account: account)
        let audioID = try await api.generateID(account: account)
        let metadataID = try await api.generateID(account: account)
        let payload = try journal.makePayload(clip, store: store)
        return ArchiveJob(clipID: clip.id, accountID: account, folderID: folder, dayKey: day,
            audio: UploadArtifact(fileID: audioID, localName: clip.fileName, mimeType: "audio/mp4", byteCount: clip.byteCount, sha256: clip.sha256),
            metadata: UploadArtifact(fileID: metadataID, localName: payload.0.lastPathComponent, mimeType: "application/json", byteCount: payload.1, sha256: payload.2))
    }
    private func finalize(_ job: ArchiveJob, clip: Clip, purge: Bool = false) async throws {
        guard job.complete else { return }
        guard let audio = try await api.file(job.audio.fileID, account: job.accountID), audio.verifies(job.audio),
              let metadata = try await api.file(job.metadata.fileID, account: job.accountID), metadata.verifies(job.metadata) else { throw CloudArchiveError.remoteMismatch }
        try checkRequestPermission()
        if purge, let boundary = latestCompleteDay, store.dayIsBlocked(boundary) { return }
        let receipt = CloudReceipt(clipID: clip.id, fileID: job.audio.fileID, metadataFileID: job.metadata.fileID,
            accountID: job.accountID, byteCount: clip.byteCount, sha256: clip.sha256, verifiedAt: Date())
        try store.commitCloudReceipt(receipt, clip: clip, purge: purge && settings.purgeAfterVerification, uploadActive: false)
        journal.discardPayload(clip.id); errorText = nil
        NotificationCenter.default.post(name: .archiveDisplayChanged, object: nil)
    }
    private func notifyOnce(id: String, title: String, body: String) {
        guard !journal.hasNotified(id) else { return }
        do {
            try journal.markNotified(id)
            DailyNotifications.shared.notify(id: "daytape." + id, title: title, body: body)
        } catch { report(error) }
    }
    private func reconcileDays(account: String) async throws {
        let complete = try store.completeDays(accountID: account, policy: routine)
        guard let latest = complete.last else { return }
        latestCompleteDay = latest.dayKey
        for day in complete { notifyOnce(id: "complete-" + day.revision, title: "当天录音已备份", body: "\(day.dayKey) · \(day.clips.count) 段") }
        guard settings.purgeAfterVerification, routine.keepLatestArchivedDay else { return }
        for clip in try store.clips() where store.hasLocalAudio(clip.id) &&
            !routine.shouldKeepLocal(clipDate: clip.startedAt, latestCompleteDay: latest.dayStart) {
            currentIsManual = ChargingBackupPolicy.manualBatchContains(clipEnd: clip.startedAt.addingTimeInterval(clip.duration), requestedThrough: manualThrough)
            try checkRequestPermission()
            guard !store.dayIsBlocked(latest.dayKey), let proof = store.cloudReceipt(clip.id), proof.accountID == account,
                  proof.matches(clip), let job = jobs[clip.id], job.complete, job.accountID == account else { continue }
            try await finalize(job, clip: clip, purge: true)
        }
    }
    private func fail(_ id: UUID, error: Error) {
        guard var job = jobs[id] else { report(error); return }
        job.lastError = error.localizedDescription; job.retryAfter = Date().addingTimeInterval(rr_retry_delay(job.attempts))
        job.attempts = min(job.attempts, 1000) + 1; jobs[id] = job
        do { try journal.save(job) } catch { report(error) }
        report(error)
    }
    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { self.legacyEventsFinished = true; self.finishLegacyEvents() }
    }
    private func finishLegacyEvents() {
        guard legacyEventsFinished, legacyTaskIDs.isEmpty, let completion = legacyCompletion else { return }
        legacyEventsFinished = false; legacyCompletion = nil; completion()
    }
    private func migrateLegacyTasks() {
        legacyUploads.getAllTasks { [weak self] tasks in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let pending = tasks.filter { $0.state != .completed }
                self.legacyTaskIDs.formUnion(pending.map(\.taskIdentifier))
                pending.forEach { $0.cancel() }
                if self.legacyTaskIDs.isEmpty {
                    self.didMigrateLegacyTasks = true; self.finishLegacyEvents(); self.requestPump()
                }
            }
        }
    }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let identifier = task.taskIdentifier
        DispatchQueue.main.async {
            self.legacyTaskIDs.remove(identifier)
            if self.legacyTaskIDs.isEmpty {
                self.didMigrateLegacyTasks = true; self.finishLegacyEvents(); self.requestPump()
            }
        }
    }
    func handleBackgroundSession(identifier: String, completion: @escaping () -> Void) {
        guard identifier == Self.backgroundID else { completion(); return }
        legacyCompletion = completion
        finishLegacyEvents()
        migrateLegacyTasks()
    }
    func registerBackgroundTasks() {
        guard !registered else { return }; registered = true
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.processingID, using: .main) { [weak self] task in
            Task { @MainActor in
                guard let self = self else { task.setTaskCompleted(success: false); return }
                self.scheduled = false
                guard self.power.connectedToPower else {
                    task.setTaskCompleted(success: false); self.schedule(); return
                }
                let id = UUID(); self.backgroundRunID = id
                self.backgroundWindow = true; self.onProcessingOpportunity?(true)
                self.backgroundRunner = Task { @MainActor in
                    async let localWork: Void = self.performBackgroundProcessingWork()
                    await self.wake(); await localWork
                    let success = !Task.isCancelled
                    if self.backgroundRunID == id {
                        self.backgroundRunID = nil; self.backgroundWindow = false
                        self.onProcessingOpportunity?(false); self.backgroundRunner = nil
                    }
                    task.setTaskCompleted(success: success); self.schedule()
                }
                task.expirationHandler = { [weak self] in
                    Task { @MainActor in
                        guard let self = self, self.backgroundRunID == id else { return }
                        self.backgroundWindow = false; self.manualThrough = nil; self.manualBatchID = nil; self.onProcessingOpportunity?(false)
                        self.work?.cancel(); self.backgroundRunner?.cancel()
                    }
                }
            }
        }
        schedule()
    }
    private func performBackgroundProcessingWork() async {
        guard power.connectedToPower, !Task.isCancelled else { return }
        await processDuringBackgroundOpportunity?()
    }
    private func schedule() {
        guard registered, (settings.enabled || processDuringBackgroundOpportunity != nil), !scheduled else { return }
        let request = BGProcessingTaskRequest(identifier: Self.processingID)
        request.requiresNetworkConnectivity = settings.enabled
        request.requiresExternalPower = true
        request.earliestBeginDate = Date().addingTimeInterval(15 * 60)
        do { try BGTaskScheduler.shared.submit(request); scheduled = true }
        catch { /* Foreground work and later system opportunities remain available. */ }
    }
}

extension Notification.Name {
    static let archiveDisplayChanged = Notification.Name("daytape.archive.display.changed")
}
