import Foundation
import Combine
import UIKit
import BackgroundTasks
import Network

@MainActor
final class NightArchiveController: NSObject, ObservableObject, URLSessionTaskDelegate {
    static var backgroundID: String { (Bundle.main.bundleIdentifier ?? "com.aimanjack.daytape") + ".drive-upload" }
    static var processingID: String { (Bundle.main.bundleIdentifier ?? "com.aimanjack.daytape") + ".nightarchive" }
    @Published private(set) var settings: ArchiveSettings
    @Published private(set) var status = "自动归档尚未启用"
    @Published private(set) var errorText: String?
    @Published private(set) var cloudCount = 0
    @Published private(set) var localCount = 0
    @Published private(set) var activeCount = 0
    @Published private(set) var latestCompleteDay: String?
    @Published private(set) var routine = DailySchedule()
    @Published private(set) var connectingBackup = false
    @Published private(set) var backupSetupError: String?
    @Published private(set) var notificationHint: String?
    var uploadClock: BackupClock { settings.resolvedUploadClock(for: routine) }
    let connection = DriveConnection()
    let sleep = SleepMonitor()
    private let store: ClipStore
    private let journal: ArchiveJournal
    private lazy var api = DriveAPI(connection: connection)
    private var jobs: [UUID: ArchiveJob] = [:]
    private var activeKeys: Set<String> = []
    private var didRestoreTasks = false
    private var pumping = false
    private var needsPass = false
    private var wifiAvailable = false
    private var registered = false
    private var scheduled = false
    private var backgroundCompletion: (() -> Void)?
    private var eventsFinished = false
    private var deferredCompletions: [(String, Int?, Error?)] = []
    private var archiveObserver: NSObjectProtocol?
    private let monitor = NWPathMonitor()
    private var boundaryTimer: Timer?
    private var manualThrough: Date?
    private lazy var uploads: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.backgroundID)
        config.sessionSendsLaunchEvents = true; config.isDiscretionary = true
        config.waitsForConnectivity = true
        config.httpMaximumConnectionsPerHost = 2
        let delegates = OperationQueue(); delegates.maxConcurrentOperationCount = 1
        return URLSession(configuration: config, delegate: self, delegateQueue: delegates)
    }()

    init(store: ClipStore) throws {
        let disk = try ArchiveJournal(store: store)
        let initialSettings = try disk.settings()
        self.store = store; journal = disk
        settings = initialSettings; routine = try store.dailySchedule()
        _ = DailyNotifications.shared
        super.init()
        for job in try journal.jobs() { jobs[job.clipID] = job }
        sleep.onEvidence = { [weak self] date in self?.sleepEvidence(date) }
        sleep.onError = { [weak self] error in self?.report(error) }
        archiveObserver = NotificationCenter.default.addObserver(forName: .archiveChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.requestPump() }
        }
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied && (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet))
            DispatchQueue.main.async { self?.wifiAvailable = available; self?.requestPump() }
        }
        monitor.start(queue: DispatchQueue(label: "daytape.network"))
        uploads.getAllTasks { [weak self] tasks in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.activeKeys = Set(tasks.compactMap(\.taskDescription))
                self.activeCount = tasks.count; self.didRestoreTasks = true
                self.requestPump()
            }
        }
        if settings.enabled && settings.useSleepRecords && settings.requestedSleepAccess { sleep.start() }
        refreshCounts(); armBoundary()
    }
    deinit {
        monitor.cancel(); boundaryTimer?.invalidate()
        if let archiveObserver = archiveObserver { NotificationCenter.default.removeObserver(archiveObserver) }
    }
    func report(_ error: Error) { errorText = error.localizedDescription; status = "等待重试 · 本地录音保留" }
    func change(_ body: (inout ArchiveSettings) -> Void) {
        do {
            var next = settings; body(&next); try journal.save(next)
            let restrictNetwork = next.wifiOnly && !settings.wifiOnly
            settings = next
            if !settings.useSleepRecords { sleep.stop() }
            if restrictNetwork { uploads.getAllTasks { tasks in tasks.forEach { $0.cancel() } } }
            if !settings.enabled {
                sleep.stop()
                uploads.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.processingID)
                scheduled = false
            }
            schedule(); requestPump()
        } catch { report(error) }
    }
    func enable(_ enabled: Bool) async {
        if !enabled { change { $0.enabled = false }; return }
        do {
            _ = try await connection.access()
            if settings.useSleepRecords && !settings.requestedSleepAccess {
                guard sleep.available else {
                    status = "本构建未配置睡眠权限，可启用夜间时间窗口。"; return
                }
                try await sleep.requestAccess()
                change { $0.requestedSleepAccess = true }
            }
            change { $0.enabled = true }
            if settings.useSleepRecords { sleep.start() }
            await wake()
        } catch { report(error) }
    }
    /// Connecting an account does not turn on uploads. Setup commits all options together.
    func beginBackupSetup() { backupSetupError = nil }
    func connectBackupAccount() async -> Bool {
        guard !connectingBackup else { return false }
        guard activeKeys.isEmpty else {
            backupSetupError = "请先关闭自动备份，等待当前上传停止后再连接其他账户。"; return false
        }
        connectingBackup = true; backupSetupError = nil
        defer { connectingBackup = false }
        do {
            try await connection.connect(); errorText = nil; return true
        } catch {
            backupSetupError = connection.configured ?
                "Google Drive 尚未连接。你可以重试，也可以暂时只保存在手机。" : CloudArchiveError.setupRequired.localizedDescription
            return false
        }
    }
    func saveAutomaticBackup(clock: BackupClock, wifiOnly: Bool, keepOneDay: Bool) async -> Bool {
        guard clock.isValid(for: routine) else {
            backupSetupError = "请选择录音结束后到次日早晨之间的备份时间。"; return false
        }
        backupSetupError = nil
        do {
            _ = try await connection.access()
            var next = settings
            next.enabled = true; next.useSleepRecords = false; next.fallbackEnabled = false
            next.uploadClock = clock; next.wifiOnly = wifiOnly; next.purgeAfterVerification = keepOneDay
            let restrictNetwork = next.wifiOnly && !settings.wifiOnly
            try journal.save(next); settings = next; errorText = nil; manualThrough = nil
            sleep.stop()
            if restrictNetwork { uploads.getAllTasks { tasks in tasks.forEach { $0.cancel() } } }
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.processingID); scheduled = false
            armBoundary(); schedule(); requestPump()
            return true
        } catch {
            backupSetupError = "没有保存这次更改。原来的设置会保留，请检查连接后重试。"; return false
        }
    }
    func restoreBackupConnection() async {
        guard settings.enabled else { return }
        do { _ = try await connection.access() }
        catch { status = "暂时无法确认 Google Drive 连接；本地录音保留，可稍后重新连接。" }
    }
    func disconnect() {
        guard activeKeys.isEmpty else { status = "请先停用归档并等待在途上传结束。"; return }
        change { $0.enabled = false }; connection.signOut()
    }
    func configureRoutine() async {
        notificationHint = nil
        do {
            try store.saveDailySchedule(routine)
            try await DailyNotifications.shared.configure(routine, morningReminder: false)
            status = "完成通知已开启"
            armBoundary()
        } catch { notificationHint = "通知未开启" }
    }
    private func armBoundary() {
        boundaryTimer?.invalidate()
        guard routine.enabled, routine.isValid else { return }
        let now = Date(), calendar = routine.calendar
        var times = DateComponents(); times.hour = uploadClock.hour; times.minute = uploadClock.minute; times.second = 0
        guard let next = calendar.nextDate(after: now, matching: times, matchingPolicy: .nextTime) else { return }
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.wake() }
        }
        boundaryTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func applyDailyStop() {
        guard settings.enabled, let cutoff = routine.latestStop(at: Date()),
              cutoff > (settings.archiveThrough ?? .distantPast) else { return }
        change { $0.archiveThrough = cutoff }
    }
    func archiveNow() {
        guard settings.enabled else { status = "请先启用自动归档。"; return }
        manualThrough = Date(); change { $0.archiveThrough = max($0.archiveThrough ?? .distantPast, manualThrough!) }
    }
    func sleepEvidence(_ end: Date) {
        guard settings.enabled && settings.useSleepRecords,
              end <= Date(), end > (settings.lastSleepEvidence ?? .distantPast) else { return }
        // Use the evidence time, never 'now'; delayed morning delivery must not sweep in later daytime audio.
        change {
            $0.lastSleepEvidence = end
            $0.archiveThrough = max($0.archiveThrough ?? .distantPast, end)
        }
    }
    private func applyFallback(now: Date = Date()) {
        guard settings.enabled, settings.fallbackEnabled else { return }
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: now)
        guard let target = calendar.date(bySettingHour: settings.fallbackHour, minute: settings.fallbackMinute, second: 0, of: day) else { return }
        let candidate = now >= target ? target : (calendar.date(byAdding: .day, value: -1, to: target) ?? target)
        let key = ISO8601DateFormatter().string(from: candidate)
        guard settings.lastFallbackDay != key else { return }
        // This is explicitly a time window, not proof of being asleep.
        change {
            $0.lastFallbackDay = key
            $0.archiveThrough = max($0.archiveThrough ?? .distantPast, candidate)
        }
    }
    func wake() async {
        if settings.enabled && settings.useSleepRecords && settings.requestedSleepAccess {
            do { if let evidence = try await sleep.latestSleep() { sleepEvidence(evidence) } }
            catch { report(error) }
        }
        applyDailyStop(); applyFallback(); armBoundary(); schedule(); await pump()
    }
    func requestPump() { Task { @MainActor in await pump() } }
    private func refreshCounts() {
        guard let clips = try? store.clips() else { return }
        localCount = clips.filter { store.hasLocalAudio($0.id) }.count
        cloudCount = clips.filter { store.cloudReceipt($0.id)?.matches($0) == true }.count
    }
    private func pump() async {
        guard !pumping else { needsPass = true; return }
        pumping = true
        defer {
            pumping = false; refreshCounts(); schedule()
            let completions = deferredCompletions; deferredCompletions.removeAll()
            for entry in completions { completed(key: entry.0, statusCode: entry.1, error: entry.2) }
            finishBackgroundEvents()
            if needsPass { needsPass = false; requestPump() }
        }
        guard didRestoreTasks else { return }
        guard settings.enabled else { status = "自动归档尚未启用"; return }
        applyDailyStop()
        guard manualThrough != nil || uploadClock.due(at: Date(), recording: routine) else { status = "等待每天 " + uploadClock.label + " 备份 · 本地录音保留"; return }
        guard let cutoff = settings.archiveThrough else { status = "等待达拉斯 22:00 归档时间"; return }
        guard !settings.wifiOnly || wifiAvailable else { status = "等待 Wi-Fi · 本地录音保留"; return }
        do {
            let auth = try await connection.access()
            for clip in try store.clips() {
                try Task.checkCancellation()
                guard settings.enabled else { return }
                guard rr_archive_eligible(clip.startedAt.addingTimeInterval(clip.duration).timeIntervalSince1970,
                                          cutoff.timeIntervalSince1970, 1) != 0 else { continue }
                // Already evicted clips retain their small index and remote link, not their audio bytes.
                guard store.hasLocalAudio(clip.id) else { continue }
                if let proof = store.cloudReceipt(clip.id), proof.accountID == auth.account, proof.matches(clip) { continue }
                var job: ArchiveJob
                if let existing = jobs[clip.id] { job = existing }
                else {
                    guard activeKeys.count < 2 else { break }
                    job = try await makeJob(clip, account: auth.account)
                    jobs[clip.id] = job; try journal.save(job)
                }
                guard job.accountID == auth.account else { throw CloudArchiveError.accountChanged }
                guard Date() >= job.retryAfter else { continue }
                do {
                    if job.complete {
                        try await finalize(job, clip: clip)
                        continue
                    }
                    for kind in ["audio", "metadata"] {
                        let key = clip.id.uuidString + "|" + kind
                        guard !activeKeys.contains(key) else { continue }
                        var item = kind == "audio" ? job.audio : job.metadata
                        if item.phase == .verified { continue }
                        // Reconcile against a fixed remote ID after relaunch, expired sessions or lost HTTP responses.
                        if let remote = try await api.file(item.fileID, account: job.accountID) {
                            guard remote.verifies(item) else { throw CloudArchiveError.remoteMismatch }
                            item.phase = .verified; item.sessionURL = nil
                        } else {
                            guard activeKeys.count < 2 else { break }
                            let path = kind == "audio" ? store.audioURL(clip.id) : journal.payloadURL(clip.id)
                            let pair = try store.hash(path)
                            guard pair.0 == item.byteCount, pair.1 == item.sha256 else { throw CloudArchiveError.remoteMismatch }
                            // A new short session is safe because the file ID is stable; never blind-append after 308.
                            guard settings.enabled, manualThrough != nil || uploadClock.due(at: Date(), recording: routine) else { return }
                            item.sessionURL = try await api.begin(item, job: job)
                            item.phase = .transferring
                            if kind == "audio" { job.audio = item } else { job.metadata = item }
                            jobs[clip.id] = job; try journal.save(job)
                            let token = try await connection.access(expectedAccount: job.accountID)
                            guard settings.enabled, manualThrough != nil || uploadClock.due(at: Date(), recording: routine) else { return }
                            var request = URLRequest(url: item.sessionURL!); request.httpMethod = "PUT"
                            request.setValue("Bearer \(token.token)", forHTTPHeaderField: "Authorization")
                            request.setValue(item.mimeType, forHTTPHeaderField: "Content-Type")
                            request.setValue(String(item.byteCount), forHTTPHeaderField: "Content-Length")
                            request.allowsCellularAccess = !settings.wifiOnly
                            request.allowsExpensiveNetworkAccess = !settings.wifiOnly
                            request.allowsConstrainedNetworkAccess = !settings.wifiOnly
                            let task = uploads.uploadTask(with: request, fromFile: path)
                            task.taskDescription = key
                            activeKeys.insert(key); activeCount = activeKeys.count
                            task.resume()
                            notifyOnce(id: "queued-" + routine.dayKey(clip.startedAt), title: "开始归档当天录音",
                                body: "上传已排队。")
                        }
                        if kind == "audio" { job.audio = item } else { job.metadata = item }
                        jobs[clip.id] = job; try journal.save(job)
                    }
                    if job.complete { try await finalize(job, clip: clip) }
                } catch {
                    fail(clip.id, error: error)
                }
            }
            try await reconcileDays(account: auth.account)
            if activeKeys.isEmpty { manualThrough = nil }
            if errorText == nil { status = activeKeys.isEmpty ? "等待下次后台机会，自动检查待归档录音" : "后台上传已排队 · \(activeKeys.count) 项" }
        } catch { report(error) }
    }
    private func makeJob(_ clip: Clip, account: String) async throws -> ArchiveJob {
        let pair = try store.hash(store.audioURL(clip.id))
        guard pair.0 == clip.byteCount, pair.1 == clip.sha256 else { throw CloudArchiveError.remoteMismatch }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"; formatter.timeZone = routine.calendar.timeZone
        let day = formatter.string(from: clip.startedAt)
        let folder = try await api.folder(day: day, account: account)
        let audioID = try await api.generateID(account: account)
        let metadataID = try await api.generateID(account: account)
        let payload = try journal.makePayload(clip, store: store)
        return ArchiveJob(clipID: clip.id, accountID: account, folderID: folder, dayKey: day,
                          audio: UploadArtifact(fileID: audioID, localName: clip.fileName, mimeType: "audio/mp4", byteCount: clip.byteCount, sha256: clip.sha256),
                          metadata: UploadArtifact(fileID: metadataID, localName: payload.0.lastPathComponent, mimeType: "application/json", byteCount: payload.1, sha256: payload.2))
    }
    private func finalize(_ job: ArchiveJob, clip: Clip, purge: Bool = false) async throws {
        guard job.complete, !activeKeys.contains(clip.id.uuidString+"|audio"), !activeKeys.contains(clip.id.uuidString+"|metadata") else { return }
        guard let audio = try await api.file(job.audio.fileID, account: job.accountID), audio.verifies(job.audio),
              let metadata = try await api.file(job.metadata.fileID, account: job.accountID), metadata.verifies(job.metadata) else {
            throw CloudArchiveError.remoteMismatch
        }
        guard settings.enabled else { return }
        if purge, let boundary = latestCompleteDay, store.dayIsBlocked(boundary) { return }
        let receipt = CloudReceipt(clipID: clip.id, fileID: job.audio.fileID, metadataFileID: job.metadata.fileID,
                                   accountID: job.accountID, byteCount: clip.byteCount, sha256: clip.sha256, verifiedAt: Date())
        try store.commitCloudReceipt(receipt, clip: clip, purge: purge && settings.purgeAfterVerification, uploadActive: false)
        journal.discardPayload(clip.id)
        errorText = nil
        NotificationCenter.default.post(name: .archiveDisplayChanged, object: nil)
    }
    private func notifyOnce(id: String, title: String, body: String) {
        guard !journal.hasNotified(id) else { return }
        do {
            // Persist the deduplication marker first; a crash may miss a notice, never duplicate deletion.
            try journal.markNotified(id)
            DailyNotifications.shared.notify(id: "daytape." + id, title: title, body: body)
        } catch { report(error) }
    }
    private func reconcileDays(account: String) async throws {
        let complete = try store.completeDays(accountID: account, policy: routine)
        guard let latest = complete.last else { return }
        latestCompleteDay = latest.dayKey
        for day in complete {
            notifyOnce(id: "complete-" + day.revision, title: "当天录音已归档",
                body: "\(day.dayKey) · \(day.clips.count) 段")
        }
        guard settings.enabled, settings.purgeAfterVerification, routine.keepLatestArchivedDay else { return }
        for clip in try store.clips() where store.hasLocalAudio(clip.id) &&
            !routine.shouldKeepLocal(clipDate: clip.startedAt, latestCompleteDay: latest.dayStart) {
            try Task.checkCancellation()
            guard settings.enabled, !store.dayIsBlocked(latest.dayKey) else { return }
            guard let proof = store.cloudReceipt(clip.id), proof.accountID == account, proof.matches(clip),
                  let job = jobs[clip.id], job.complete, job.accountID == account,
                  !activeKeys.contains(clip.id.uuidString + "|audio"), !activeKeys.contains(clip.id.uuidString + "|metadata") else { continue }
            // Re-read both remote hashes immediately before removing each older local file.
            // Drive copies are never deleted by this app.
            try await finalize(job, clip: clip, purge: true)
        }
    }
    private func fail(_ id: UUID, error: Error) {
        guard var job = jobs[id] else { report(error); return }
        job.lastError = error.localizedDescription
        job.retryAfter = Date().addingTimeInterval(rr_retry_delay(job.attempts))
        job.attempts = min(job.attempts, 1000) + 1
        jobs[id] = job
        do { try journal.save(job) } catch { report(error) }
        report(error)
    }
    private func completed(key: String, statusCode: Int?, error: Error?) {
        // An API await may yield while a copied job is being edited. Reconcile completions
        // after that pass so a stale local value cannot overwrite another artifact's journal.
        if pumping { deferredCompletions.append((key, statusCode, error)); return }
        activeKeys.remove(key); activeCount = activeKeys.count
        let pieces = key.split(separator: "|")
        guard pieces.count == 2, let id = UUID(uuidString: String(pieces[0])), var job = jobs[id] else { return }
        let kind = String(pieces[1]); guard kind == "audio" || kind == "metadata" else { return }
        var item = kind == "audio" ? job.audio : job.metadata
        item.phase = .needsVerification; item.sessionURL = nil
        if kind == "audio" { job.audio = item } else { job.metadata = item }
        jobs[id] = job
        do { try journal.save(job) } catch { report(error); return }
        if let error = error { fail(id, error: error) }
        else if let code = statusCode, !(200..<300).contains(code) { fail(id, error: CloudArchiveError.http(code)) }
        requestPump()
    }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let key = task.taskDescription else { return }
        let code = (task.response as? HTTPURLResponse)?.statusCode
        DispatchQueue.main.async { self.completed(key: key, statusCode: code, error: error) }
    }
    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            self.eventsFinished = true; self.schedule(); self.finishBackgroundEvents()
        }
    }
    private func finishBackgroundEvents() {
        guard eventsFinished, !pumping, deferredCompletions.isEmpty else { return }
        eventsFinished = false
        let completion = backgroundCompletion; backgroundCompletion = nil; completion?()
    }
    func handleBackgroundSession(identifier: String, completion: @escaping () -> Void) {
        guard identifier == Self.backgroundID else { completion(); return }
        backgroundCompletion = completion; _ = uploads
    }
    func registerBackgroundTasks() {
        guard !registered else { return }; registered = true
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.processingID, using: .main) { [weak self] task in
            DispatchQueue.main.async {
                guard let self = self else { task.setTaskCompleted(success: false); return }
                self.scheduled = false
                let run = Task { @MainActor in await self.wake(); task.setTaskCompleted(success: !Task.isCancelled) }
                task.expirationHandler = { run.cancel() }
            }
        }
        schedule()
    }
    private func schedule() {
        guard registered, settings.enabled, !scheduled else { return }
        let request = BGProcessingTaskRequest(identifier: Self.processingID)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        let now = Date()
        if uploadClock.due(at: now, recording: routine) { request.earliestBeginDate = now.addingTimeInterval(15 * 60) }
        else {
            request.earliestBeginDate = uploadClock.nextStart(after: now, recording: routine) ?? now.addingTimeInterval(15 * 60)
        }
        do { try BGTaskScheduler.shared.submit(request); scheduled = true }
        catch { /* Foreground, HealthKit and URLSession callbacks remain available; do not discard jobs. */ }
    }
}

extension Notification.Name {
    static let archiveDisplayChanged = Notification.Name("daytape.archive.display.changed")
}
