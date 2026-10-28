import Foundation
import Combine
import NaturalLanguage
import UIKit
import CryptoKit

private actor LocalTranscriptSearch {
    struct Result { let hits: [SearchHit]; let semanticAvailable: Bool }
    private var embeddings: [NLLanguage: NLEmbedding] = [:]
    func find(_ query: String, documents: [TranscriptDocument], semantic: Bool,
              localeIdentifier: String) -> Result {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return Result(hits: [], semanticAvailable: true) }
        let language = NLLanguageRecognizer.dominantLanguage(for: query)
            ?? NLLanguage(rawValue: Locale(identifier: localeIdentifier).languageCode ?? "en")
        var model: NLEmbedding?
        if semantic {
            if let cached = embeddings[language] { model = cached }
            else if let loaded = NLEmbedding.sentenceEmbedding(for: language) {
                embeddings[language] = loaded; model = loaded
            }
        }
        let vector = model?.vector(for: query)
        var hits: [SearchHit] = []
        for document in documents {
            for segment in document.segments where !segment.text.isEmpty {
                let keyword = IntelligenceMath.keywordScore(query: query, text: segment.text)
                var similarity = 0.0
                if let vector, let other = model?.vector(for: segment.text),
                   let cosine = IntelligenceMath.cosineSimilarity(vector, other) { similarity = cosine }
                guard keyword > 0 || (semantic && similarity >= 0.45) else { continue }
                hits.append(SearchHit(clipID: document.clipID, offset: segment.offset, text: segment.text,
                                      score: keyword * 2 + max(0, similarity), startedAt: document.startedAt))
            }
        }
        return Result(hits: hits.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.startedAt > b.startedAt
        }.prefix(100).map { $0 }, semanticAvailable: !semantic || vector != nil)
    }
}

@MainActor
final class IntelligenceController: ObservableObject {
    @Published var settings = IntelligenceSettings()
    @Published private(set) var documents: [TranscriptDocument] = []
    @Published private(set) var jobs: [TranscriptionJob] = []
    @Published private(set) var reviews: [AIReview] = []
    @Published private(set) var memories: [MemoryFact] = []
    @Published private(set) var searchResults: [SearchHit] = []
    @Published private(set) var isProcessing = false
    @Published private(set) var isAIProcessing = false
    @Published private(set) var status = "尚未转写"
    @Published var lastError: String?
    @Published private(set) var answer: AIReview?
    @Published private(set) var reviewProgress: AIReviewProgress?
    @Published private(set) var pendingDeletionCount = 0
    @Published private(set) var deletionCleanupError: String?

    let store: ClipStore
    private var disk: IntelligenceDisk?
    private let speech = LocalSpeechTranscriber()
    private let remoteSpeech = RemoteSpeechTranscriber()
    private let localSearch = LocalTranscriptSearch()
    private var processTask: Task<Void, Never>?
    private var remoteTask: Task<AIWireReply, Error>?
    private var dayReviewTask: Task<DayReviewOutput, Error>?
    private var searchGeneration = UUID()
    private var remoteGeneration = UUID()
    private var savedSettings = IntelligenceSettings()
    private var clipIndex: [UUID: Clip] = [:]
    private var archiveObserver: NSObjectProtocol?
    private var batteryObserver: NSObjectProtocol?
    private var activeClipID: UUID?
    private var excludedClipIDs: Set<UUID> = []
    private var queuePaused = false
    private var executionAllowed = false
    private var automaticReviewAttempts: [String: Date] = [:]
    private var activeWorkerIsManual = false
    private var pendingDeletionIDs: Set<UUID> = []
    private var reconciledDeletionIDs: Set<UUID> = []
    private var deletionValidationFailed = false

    static var supportedLocales: [Locale] { LocalSpeechTranscriber.supportedLocales }
    var hasAPIKey: Bool { ((try? IntelligenceKeychain.read()) ?? nil)?.isEmpty == false }
    var hasRemoteASRKey: Bool { ((try? IntelligenceKeychain.read(account: "speech-api-key")) ?? nil)?.isEmpty == false }
    var transcriptionBackend: IntelligenceSettings.TranscriptionBackend { settings.transcriptionBackend ?? .onDevice }
    var pendingClipIDs: Set<UUID> {
        Set(jobs.filter { $0.state != .completed }.map(\.clipID))
    }

    init(store: ClipStore) {
        self.store = store
        do {
            let authoritativeDeleted = try store.deletedClipIDs()
            let storage = try IntelligenceDisk(root: store.root)
            let snapshot = try storage.load()
            let restored = try storage.documents()
            disk = storage; settings = snapshot.settings; savedSettings = snapshot.settings
            excludedClipIDs = Set(snapshot.excludedClipIDs ?? []).union(authoritativeDeleted)
            documents = restored.filter { !excludedClipIDs.contains($0.clipID) }
            func current(_ source: SourceCitation) -> Bool {
                documents.contains { document in document.clipID == source.clipID && document.segments.contains {
                    abs($0.offset - source.offset) < 0.001 && $0.text == source.text
                } }
            }
            reviews = snapshot.reviews.filter { $0.citations.allSatisfy(current) }
            memories = snapshot.memories.filter { $0.sourceCitations.allSatisfy(current) }
            queuePaused = snapshot.transcriptionPaused ?? false
            automaticReviewAttempts = snapshot.automaticReviewAttempts ?? [:]
            reviewProgress = try storage.progress()
            if reviewProgress?.phase != .completed {
                reviewProgress?.phase = .paused
                reviewProgress?.message = "上次处理未完成，选择原日期和类型可复用已保存分块继续。"
            }
            jobs = snapshot.jobs.map { old in
                var job = old
                if job.state == .running { job.state = .paused; job.error = "上次转写中断，可从已保存窗口续接。" }
                return job
            }
            filterDeletedContent()
            try persist()
            refresh()
        } catch {
            disk = nil; lastError = "无法读取本地智能记录：\(error.localizedDescription)。已有文件未覆盖。"
            status = "本地索引不可用"
            if let deleted = try? store.deletedClipIDs() {
                excludedClipIDs.formUnion(deleted); filterDeletedContent()
                pendingDeletionIDs.formUnion(excludedClipIDs); pendingDeletionCount = pendingDeletionIDs.count
            } else {
                deletionValidationFailed = true
                documents = []; reviews = []; searchResults = []; answer = nil
                memories.removeAll { !$0.sourceCitations.isEmpty || $0.inputClipIDs != nil }
            }
        }
        archiveObserver = NotificationCenter.default.addObserver(forName: .archiveChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        UIDevice.current.isBatteryMonitoringEnabled = true
        batteryObserver = NotificationCenter.default.addObserver(forName: UIDevice.batteryStateDidChangeNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if !self.connectedToPower && self.transcriptionBackend == .configuredService && !self.activeWorkerIsManual {
                    self.processTask?.cancel(); self.remoteSpeech.cancel()
                }
                if self.connectedToPower && self.executionAllowed { self.refresh(); await self.automaticWorkIfAllowed() }
            }
        }
    }

    deinit {
        if let archiveObserver { NotificationCenter.default.removeObserver(archiveObserver) }
        if let batteryObserver { NotificationCenter.default.removeObserver(batteryObserver) }
    }

    func refresh() {
        do {
            let authoritative = try store.deletedClipIDs()
            let newlyDeleted = authoritative.subtracting(excludedClipIDs)
            if !newlyDeleted.isEmpty { invalidateAIWork() }
            excludedClipIDs.formUnion(authoritative)
            if deletionValidationFailed || disk == nil {
                let storage = try disk ?? IntelligenceDisk(root: store.root)
                let snapshot = try storage.load()
                excludedClipIDs.formUnion(snapshot.excludedClipIDs ?? [])
                documents = try storage.documents().filter { !excludedClipIDs.contains($0.clipID) }
                reviews = snapshot.reviews.filter { reviewAllowedAfterDeletion($0) }
                memories = snapshot.memories.filter { memoryAllowedAfterDeletion($0) }
                jobs = snapshot.jobs.filter { !excludedClipIDs.contains($0.clipID) }
                settings = snapshot.settings; savedSettings = snapshot.settings; disk = storage
            }
            deletionValidationFailed = false
            filterDeletedContent()
            try reconcileDeletedContent()
        } catch {
            // A malformed deletion receipt must not let an earlier snapshot resurrect text.
            if (try? store.deletedClipIDs()) == nil {
                deletionValidationFailed = true
                processTask?.cancel(); speech.cancel(); remoteSpeech.cancel(); invalidateAIWork()
                documents = []; reviews = []; searchResults = []; answer = nil
                memories.removeAll { !$0.sourceCitations.isEmpty || $0.inputClipIDs != nil }
            }
            deletionCleanupError = error.localizedDescription; report(error)
            return
        }
        guard disk != nil else { return }
        do {
            clipIndex = Dictionary(uniqueKeysWithValues: try store.clips().map { ($0.id, $0) })
            if settings.automaticTranscription {
                try enqueue(day: nil, includeFailed: false)
                if executionAllowed, !queuePaused, processTask == nil, jobs.contains(where: { $0.state == .pending }) { beginProcessing() }
            }
        } catch { report(error) }
    }

    func retryPendingDeletions() { refresh() }

    func saveSettings() {
        if settings.apiBaseURL != savedSettings.apiBaseURL {
            settings.remoteAIEnabled = false; invalidateAIWork()
        }
        if settings.remoteASRBaseURL != savedSettings.remoteASRBaseURL {
            settings.remoteASRSharingEnabled = false
            if transcriptionBackend == .configuredService { processTask?.cancel(); remoteSpeech.cancel() }
        }
        let requestedRemoteDisable = !settings.remoteAIEnabled
        let requestedASRDisable = settings.remoteASRSharingEnabled != true
        do {
            if settings.remoteAIEnabled {
                _ = try CompatibleAIClient.endpoint(settings.apiBaseURL)
                guard !settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, hasAPIKey else {
                    throw IntelligenceError.message("请先保存 API 密钥、HTTPS 地址和模型，再开启远程 AI。")
                }
            }
            if settings.remoteASRSharingEnabled == true {
                _ = try RemoteSpeechTranscriber.endpoint(settings.remoteASRBaseURL ?? "")
                guard !(settings.remoteASRModel ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, hasRemoteASRKey else {
                    throw IntelligenceError.message("请先保存独立的转写服务密钥、HTTPS 地址和模型，再允许分享录音。")
                }
            }
            if backendIdentifier(settings) != backendIdentifier(savedSettings), isProcessing { pauseTranscription() }
            if savedSettings.remoteASRSharingEnabled == true && requestedASRDisable { pauseTranscription() }
            if settings.localeIdentifier != savedSettings.localeIdentifier, isProcessing { pauseTranscription() }
            if savedSettings.automaticTranscription && !settings.automaticTranscription { pauseTranscription() }
            if !savedSettings.automaticTranscription && settings.automaticTranscription { queuePaused = false }
            if !settings.remoteAIEnabled {
                invalidateAIWork()
            }
            try persist(); savedSettings = settings; lastError = nil
            if settings.automaticTranscription { refresh() }
        } catch {
            settings = savedSettings
            // A failed settings write must never silently re-enable outbound processing in this process.
            if requestedRemoteDisable { settings.remoteAIEnabled = false; invalidateAIWork() }
            if requestedASRDisable { settings.remoteASRSharingEnabled = false; processTask?.cancel(); remoteSpeech.cancel() }
            report(error)
        }
    }

    func setAPIKey(_ key: String) throws {
        try IntelligenceKeychain.save(key)
        if key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            settings.remoteAIEnabled = false; saveSettings()
        }
        objectWillChange.send()
    }
    func setRemoteASRKey(_ key: String) throws {
        try IntelligenceKeychain.save(key, account: "speech-api-key")
        if key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            settings.remoteASRSharingEnabled = false; pauseTranscription(); saveSettings()
        }
        objectWillChange.send()
    }

    func startTranscription(day: Date? = nil) {
        guard processTask == nil else { return }
        do {
            queuePaused = false
            executionAllowed = true // An explicit UI action occurs while the app is running.
            clipIndex = Dictionary(uniqueKeysWithValues: try store.clips().map { ($0.id, $0) })
            try enqueue(day: day, includeFailed: true)
            beginProcessing(day: day, manual: true)
        } catch { report(error) }
    }

    func pauseTranscription() {
        queuePaused = true
        processTask?.cancel(); speech.cancel(); remoteSpeech.cancel()
        do { try persist() } catch { report(error) }
        status = "转写已暂停，完成的窗口已保存"
    }

    func retryFailed() { startTranscription() }

    func pauseAIProcessing() {
        invalidateAIWork()
        status = "AI 处理已暂停，完成的分块会在继续时复用"
    }

    func setExecutionOpportunity(_ allowed: Bool) {
        executionAllowed = allowed
        if allowed { refresh() }
        else {
            // System expiration must not overwrite the user's persistent pause preference.
            processTask?.cancel(); speech.cancel(); remoteSpeech.cancel()
            invalidateAIWork()
        }
    }

    func automaticWorkIfAllowed() async {
        guard executionAllowed else { return }
        refresh()
        guard settings.automaticReview, settings.remoteAIEnabled, !isAIProcessing else { return }
        UIDevice.current.isBatteryMonitoringEnabled = true
        let power = UIDevice.current.batteryState
        guard power == .charging || power == .full else { return }
        do {
            let schedule = try store.dailySchedule()
            guard let latest = schedule.latestStop(at: Date()) else { return }
            let dayKey = schedule.dayKey(latest)
            guard !store.dayIsBlocked(dayKey),
                  let closure = try store.dayClosures().map(\.1).first(where: { $0.dayKey == dayKey }),
                  closure.cutoff <= Date(),
                  closure.matches(clipIndex.values.filter { schedule.dayKey($0.startedAt) == dayKey }),
                  closure.clips.allSatisfy({ clip in documents.contains { $0.clipID == clip.id && $0.isComplete && $0.sourceSHA256 == clip.sha256 } }) else { return }
            for kind in [AIReview.Kind.summary, .reflection] {
                guard executionAllowed, settings.automaticReview, settings.remoteAIEnabled else { return }
                let currentPower = UIDevice.current.batteryState
                guard currentPower == .charging || currentPower == .full else { return }
                guard !reviews.contains(where: { $0.kind == kind && sameDay($0.day, closure.dayStart) && $0.pendingTranscriptCount == 0 }) else { continue }
                let attemptKey = dayKey + "|" + kind.rawValue
                if let last = automaticReviewAttempts[attemptKey], Date().timeIntervalSince(last) < 3600 { return }
                automaticReviewAttempts[attemptKey] = Date()
                try persist()
                await generateReview(day: closure.dayStart, kind: kind, requiresCharging: true)
                if lastError != nil { return }
            }
        } catch { report(error) }
    }

    func processDuringGrantedOpportunity() async {
        guard executionAllowed, !Task.isCancelled else { return }
        await withTaskCancellationHandler(operation: {
            while settings.automaticTranscription, executionAllowed, !Task.isCancelled {
                refresh()
                guard let running = processTask else { break }
                await running.value
                if lastError != nil { break }
            }
            guard !Task.isCancelled, executionAllowed else { return }
            await automaticWorkIfAllowed()
        }, onCancel: { [weak self] in
            Task { @MainActor in
                self?.processTask?.cancel(); self?.speech.cancel(); self?.remoteSpeech.cancel(); self?.invalidateAIWork()
            }
        })
    }

    func search(_ query: String, semantic: Bool = true) {
        lastError = nil
        let generation = UUID(); searchGeneration = generation
        let snapshot = documents, locale = settings.localeIdentifier
        Task {
            let result = await localSearch.find(query, documents: snapshot, semantic: semantic, localeIdentifier: locale)
            guard generation == searchGeneration else { return }
            searchResults = result.hits
            if semantic && !result.semanticAvailable { status = "此语言没有可用本机语义模型，已返回关键词结果" }
            else { status = "找到 \(result.hits.count) 个本地片段" }
        }
    }

    func updateDocument(_ document: TranscriptDocument) throws {
        guard disk != nil, let original = documents.first(where: { $0.clipID == document.clipID }),
              original.sourceSHA256 == document.sourceSHA256,
              document.duration.isFinite, document.duration > 0,
              document.completedOffset.isFinite, document.completedOffset >= 0, document.completedOffset <= document.duration + 0.01,
              document.segments.allSatisfy({ $0.offset.isFinite && $0.duration.isFinite &&
                  $0.offset >= 0 && $0.duration >= 0 && $0.offset + $0.duration <= document.duration + 1 }) else {
            throw IntelligenceError.message("转写时间或来源不匹配，未覆盖原记录。")
        }
        var updated = document; updated.updatedAt = Date()
        try disk?.save(updated)
        upsert(updated)
        let changed = original.text != updated.text || original.segments.count != updated.segments.count ||
            zip(original.segments, updated.segments).contains { pair in
                pair.0.offset != pair.1.offset || pair.0.duration != pair.1.duration
            }
        if changed {
            invalidateAIWork()
            reviews.removeAll { $0.inputClipIDs == nil || $0.inputClipIDs?.contains(document.clipID) == true || $0.citations.contains { $0.clipID == document.clipID } }
            memories.removeAll { ($0.inputClipIDs == nil && !$0.sourceCitations.isEmpty) || $0.inputClipIDs?.contains(document.clipID) == true || $0.sourceCitations.contains { $0.clipID == document.clipID } }
            if let current = answer, current.inputClipIDs == nil || current.inputClipIDs?.contains(document.clipID) == true || current.citations.contains(where: { $0.clipID == document.clipID }) { answer = nil }
            searchGeneration = UUID(); searchResults = []
            try persist()
            try disk?.deleteAICaches(containing: document.clipID); reviewProgress = nil
        }
        lastError = nil
    }

    func deleteContent(for clipID: UUID) throws {
        excludedClipIDs.insert(clipID)
        pendingDeletionIDs.insert(clipID); reconciledDeletionIDs.remove(clipID)
        if activeClipID == clipID { pauseTranscription() }
        // A pending remote response may still include this text, so do not commit that result.
        invalidateAIWork()
        filterDeletedContent()
        try reconcileDeletedContent()
        lastError = nil
    }

    func saveMemory(_ text: String, citations: [SourceCitation] = []) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let previous = memories
        memories.append(MemoryFact(text: text, sourceCitations: citations,
            inputClipIDs: citations.isEmpty ? nil : Array(Set(citations.map(\.clipID)))))
        do { try persist(); lastError = nil } catch { memories = previous; report(error) }
    }

    func updateMemory(_ memory: MemoryFact) {
        guard let index = memories.firstIndex(where: { $0.id == memory.id }),
              !memory.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let previous = memories[index]
        memories[index] = memory; memories[index].updatedAt = Date()
        if previous.text != memory.text { memories[index].inputClipIDs = nil }
        do { try persist(); lastError = nil } catch { memories[index] = previous; report(error) }
    }

    func toggleMemory(_ id: UUID) {
        guard let index = memories.firstIndex(where: { $0.id == id }) else { return }
        let previous = memories[index]
        memories[index].isActive.toggle(); memories[index].updatedAt = Date()
        do { try persist(); lastError = nil } catch { memories[index] = previous; report(error) }
    }

    func deleteMemory(_ id: UUID) {
        let previous = memories; memories.removeAll { $0.id == id }
        do { try persist(); lastError = nil } catch { memories = previous; report(error) }
    }

    func generateReview(day: Date, kind: AIReview.Kind, requiresCharging: Bool = false) async {
        let sources = documents.filter { sameDay($0.startedAt, day) }.sorted { $0.startedAt < $1.startedAt }.flatMap { document in
            document.segments.filter { !$0.text.isEmpty }.sorted { $0.offset < $1.offset }.map {
                SourceCitation(clipID: document.clipID, offset: $0.offset, text: $0.text)
            }
        }
        if kind != .answer {
            await runDayReview(day: day, kind: kind, sources: sources, requiresCharging: requiresCharging)
            return
        }
        let instruction: String
        switch kind {
        case .summary: instruction = "总结这一天的已提供录音，区分讨论、已决定事项、待办与不确定事项。不要把讨论误写成承诺。"
        case .highlights: instruction = "选出这一天值得回看的高光、具体安排与重要对话；每项引用原片段。不虚构重要性或心理状态。"
        case .reflection: instruction = "根据这一天的录音做每日回顾。先总结事实，再把建议明确标为建议；不要诊断情绪、健康或关系。"
        case .answer: instruction = "根据这些录音回答其中明确出现的事项。"
        }
        await runAI(instruction: instruction, sources: sources, kind: kind, day: day)
    }

    func ask(_ question: String) async {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        let found = await localSearch.find(question, documents: documents, semantic: true,
                                            localeIdentifier: settings.localeIdentifier)
        let sources = found.hits.prefix(60).map { SourceCitation(clipID: $0.clipID, offset: $0.offset, text: $0.text) }
        guard !sources.isEmpty else {
            lastError = found.semanticAvailable ? "本地记录没有找到相关片段，未发送 AI 请求。" : "此语言无可用语义模型，且没有匹配关键词；请用记录中的词语再搜索。"
            return
        }
        await runAI(instruction: "回答用户问题：\(question)\n只根据所给历史片段与用户管理的记忆；没有证据就直说。", sources: sources, kind: .answer, day: Date())
    }

    /// Tests a configured provider with fixed nonpersonal text. Requires the same explicit consent.
    func testConnection() async {
        guard settings.remoteAIEnabled else { lastError = "请先明确开启远程 AI，再测试连接。"; return }
        guard !isAIProcessing else { lastError = "已有 AI 任务正在执行。"; return }
        let generation = UUID(); remoteGeneration = generation
        isAIProcessing = true; lastError = nil
        defer { if remoteGeneration == generation { isAIProcessing = false; remoteTask = nil } }
        do {
            guard let key = try IntelligenceKeychain.read(), !key.isEmpty else { throw IntelligenceError.message("未保存 API 密钥。") }
            let configuration = settings
            let call = Task { try await CompatibleAIClient.complete(settings: configuration, key: key,
                instruction: "This is a connection test containing no personal recordings. Return title=Connection test, body=Connection successful [S1], citations=[S1], memories=[].",
                context: "[S1] Fixed diagnostic text: connection test.") }
            remoteTask = call
            _ = try await withTaskCancellationHandler(operation: { try await call.value }, onCancel: { call.cancel() })
            guard remoteGeneration == generation, settings.remoteAIEnabled else { throw CancellationError() }
            status = "AI 连接成功；测试仅发送固定诊断文字"
        } catch {
            guard remoteGeneration == generation else { return }
            if isCancellation(error) { status = "AI 连接测试已取消" } else { report(error) }
        }
    }

    private func enqueue(day: Date?, includeFailed: Bool) throws {
        guard disk != nil else { throw IntelligenceError.message("本地索引不可用，无法保存转写进度。") }
        let desiredBackend = backendIdentifier(settings), desiredLocale = transcriptionLocale(settings)
        for clip in clipIndex.values.sorted(by: { $0.startedAt < $1.startedAt }) {
            if let day, !sameDay(clip.startedAt, day) { continue }
            if excludedClipIDs.contains(clip.id) {
                guard includeFailed else { continue }
                excludedClipIDs.remove(clip.id)
            }
            let document = documents.first { $0.clipID == clip.id }
            let sameBackend = document?.backendIdentifier == desiredBackend ||
                (document?.backendIdentifier == nil && transcriptionBackend == .onDevice)
            if document?.isComplete == true && document?.localeIdentifier == desiredLocale && document?.sourceSHA256 == clip.sha256 && sameBackend {
                if let index = jobs.firstIndex(where: { $0.clipID == clip.id }) {
                    jobs[index].state = .completed; jobs[index].error = nil
                    jobs[index].completedOffset = document?.completedOffset ?? clip.duration
                }
                try removeProcessingHold(clip.id)
                continue
            }
            guard store.hasLocalAudio(clip.id) else { continue }
            if let index = jobs.firstIndex(where: { $0.clipID == clip.id }) {
                if jobs[index].state == .running { continue }
                if jobs[index].state == .failed && !includeFailed { continue }
                jobs[index].state = .pending; jobs[index].error = nil
            } else { jobs.append(TranscriptionJob(clipID: clip.id)) }
            try createProcessingHold(clip.id)
        }
        try persist()
    }

    private func beginProcessing(day: Date? = nil, manual: Bool = false) {
        guard processTask == nil else { return }
        if transcriptionBackend == .configuredService {
            guard settings.remoteASRSharingEnabled == true else { status = "远程转写等待你明确允许分享录音"; return }
            if !manual && !connectedToPower { status = "自动远程转写等待手机充电"; return }
        }
        func matches(_ job: TranscriptionJob) -> Bool {
            guard job.state == .pending else { return false }
            if let day { return clipIndex[job.clipID].map { sameDay($0.startedAt, day) } ?? false }
            return true
        }
        guard jobs.contains(where: matches) else { status = "没有需要转写的本地录音"; return }
        isProcessing = true; lastError = nil
        status = transcriptionBackend == .onDevice ? "准备本机转写" : "准备所选服务转写"
        activeWorkerIsManual = manual
        processTask = Task { [weak self] in
            guard let self else { return }
            defer { self.processTask = nil; self.isProcessing = false; self.activeWorkerIsManual = false }
            do {
                if self.transcriptionBackend == .onDevice { try await self.speech.authorize() }
                while !Task.isCancelled, self.executionAllowed, !self.queuePaused, let job = self.jobs.first(where: matches) {
                    do { try await self.process(job.clipID, manual: manual) }
                    catch is CancellationError { break }
                    catch {
                        self.changeJob(job.clipID, state: .failed, error: error.localizedDescription)
                        self.queuePaused = true
                        self.report(error)
                        do { try self.persist() } catch { self.report(error); break }
                        // A missing language model or unavailable recognizer should not drain battery retrying all clips.
                        break
                    }
                }
                if !Task.isCancelled && self.lastError == nil { self.status = "转写完成，已保存到本机" }
                if !Task.isCancelled, self.executionAllowed { await self.automaticWorkIfAllowed() }
            } catch {
                self.queuePaused = true; self.report(error)
                do { try self.persist() } catch { self.report(error) }
            }
        }
    }

    private func process(_ id: UUID, manual: Bool) async throws {
        guard let clip = clipIndex[id], store.retainAudio(id) else {
            throw IntelligenceError.message("原音频暂不在本机，请先恢复音频后重试。")
        }
        activeClipID = id
        defer { if activeClipID == id { activeClipID = nil }; store.releaseAudio(id) }
        let configuration = settings
        let locale = transcriptionLocale(configuration), backend = backendIdentifier(configuration)
        let isRemote = (configuration.transcriptionBackend ?? .onDevice) == .configuredService
        var document = documents.first { $0.clipID == id && $0.sourceSHA256 == clip.sha256 && $0.localeIdentifier == locale &&
            ($0.backendIdentifier == backend || ($0.backendIdentifier == nil && !isRemote)) }
            ?? TranscriptDocument(clipID: id, startedAt: clip.startedAt, duration: clip.duration,
                localeIdentifier: locale, sourceSHA256: clip.sha256, segments: [], backendIdentifier: backend)
        changeJob(id, state: .running, error: nil)
        if let index = jobs.firstIndex(where: { $0.clipID == id }) {
            jobs[index].attempts += 1; jobs[index].completedOffset = document.completedOffset
        }
        try persist()
        do {
            while document.completedOffset < clip.duration - 0.02 {
                try Task.checkCancellation()
                let offset = document.completedOffset, duration = min(50, clip.duration - offset)
                status = "\(isRemote ? "所选服务转写" : "本机转写") \(Int(offset))/\(Int(clip.duration.rounded(.up))) 秒"
                let segments: [TranscriptSegment]
                if isRemote {
                    guard let key = try IntelligenceKeychain.read(account: "speech-api-key"), !key.isEmpty else {
                        throw IntelligenceError.message("未保存转写服务密钥；没有发送录音。")
                    }
                    segments = try await remoteSpeech.transcribe(source: store.audioURL(id), offset: offset,
                        duration: duration, settings: configuration, key: key, gate: { [weak self] in
                            guard let self, self.settings.remoteASRSharingEnabled == true,
                                  self.backendIdentifier(self.settings) == backend,
                                  self.executionAllowed, !self.excludedClipIDs.contains(id) else { throw CancellationError() }
                            if !manual && !self.connectedToPower { throw CancellationError() }
                        })
                } else {
                    segments = try await speech.transcribe(source: store.audioURL(id), offset: offset,
                                                          duration: duration, localeIdentifier: locale)
                }
                try Task.checkCancellation()
                guard !excludedClipIDs.contains(id) else { throw CancellationError() }
                document.segments.append(contentsOf: segments)
                document.completedOffset = min(clip.duration, offset + duration)
                document.updatedAt = Date()
                try commitTranscript(document)
                if let index = jobs.firstIndex(where: { $0.clipID == id }) { jobs[index].completedOffset = document.completedOffset }
                try persist()
            }
            document.isComplete = true; document.updatedAt = Date()
            try commitTranscript(document)
            changeJob(id, state: .completed, error: nil); try persist()
            try removeProcessingHold(id)
        } catch {
            if isCancellation(error) {
                changeJob(id, state: .paused, error: nil); try persist(); throw CancellationError()
            }
            throw error
        }
    }

    private func runAI(instruction: String, sources: [SourceCitation], kind: AIReview.Kind, day: Date) async {
        guard !isAIProcessing else { lastError = "已有 AI 任务正在执行。"; return }
        guard settings.remoteAIEnabled else { lastError = "请先配置并明确开启远程 AI；没有发送任何文字。"; return }
        guard !sources.isEmpty else { lastError = "还没有可用于分析的转写，未发送请求。"; return }
        let generation = UUID(); remoteGeneration = generation
        isAIProcessing = true; lastError = nil
        defer { if remoteGeneration == generation { isAIProcessing = false; remoteTask = nil } }
        do {
            guard let key = try IntelligenceKeychain.read(), !key.isEmpty else { throw IntelligenceError.message("未保存 API 密钥。") }
            var selected: [SourceCitation] = [], context = ""
            let clock = ISO8601DateFormatter()
            clock.timeZone = DailySchedule().calendar.timeZone
            for source in sources {
                let recorded = documents.first(where: { $0.clipID == source.clipID })?.startedAt
                    .addingTimeInterval(source.offset)
                let when = recorded.map { clock.string(from: $0) } ?? "unknown"
                let line = "[S\(selected.count + 1)] recordedAt=\(when) clip=\(source.clipID.uuidString) offset=\(String(format: "%.2f", source.offset))s\n\(source.text)\n"
                if context.utf8.count + line.utf8.count > 80_000 { break }
                selected.append(source); context += line
            }
            guard !selected.isEmpty else { throw IntelligenceError.message("单个片段文字过长，请缩小或编辑转写后再处理。") }
            var usedMemories: [MemoryFact] = [], memoryText = ""
            for memory in memories.filter(\.isActive).prefix(40) {
                let line = memory.text + "\n"
                if memoryText.utf8.count + line.utf8.count > 8_000 { break }
                usedMemories.append(memory); memoryText += line
            }
            var actualInputs: Set<UUID>? = Set(selected.map(\.clipID))
            for memory in usedMemories {
                guard let dependencies = memory.inputClipIDs else { actualInputs = nil; break }
                actualInputs?.formUnion(dependencies)
            }
            let inputIDs = actualInputs.map { $0.sorted { $0.uuidString < $1.uuidString } }
            if !memoryText.isEmpty { context += "\nUSER-MANAGED MEMORY (context, not a substitute for recording evidence):\n" + memoryText }
            let configuration = settings
            let call = Task { try await CompatibleAIClient.complete(settings: configuration, key: key,
                                                                   instruction: instruction, context: context) }
            remoteTask = call
            let result = try await withTaskCancellationHandler(operation: { try await call.value },
                                                               onCancel: { call.cancel() })
            guard settings.remoteAIEnabled, remoteGeneration == generation else { throw CancellationError() }
            let lookup = Dictionary(uniqueKeysWithValues: selected.enumerated().map { ("S\($0.offset + 1)", $0.element) })
            guard !result.citations.isEmpty, result.citations.allSatisfy({ lookup[$0] != nil }) else {
                throw IntelligenceError.message("AI 没有提供有效原始片段引用，结果未保存。")
            }
            let inlineTags = IntelligenceMath.sourceTags(in: result.body)
            guard !inlineTags.isEmpty, inlineTags.isSubset(of: Set(result.citations)) else {
                throw IntelligenceError.message("AI 的正文引用与原始片段不一致，结果未保存。")
            }
            var body = result.body
            // Replace model-only source tags with durable, tap-resolvable recording references.
            for (tag, source) in lookup {
                body = body.replacingOccurrences(of: "[\(tag)]", with:
                    "[\(tag)](daytape://clip/\(source.clipID.uuidString)?offset=\(source.offset))")
            }
            let missingTranscripts = clipIndex.values.contains { clip in
                sameDay(clip.startedAt, day) && !documents.contains(where: { $0.clipID == clip.id && $0.isComplete })
            }
            let incomplete = sources.count > selected.count || missingTranscripts || documents.contains { sameDay($0.startedAt, day) && !$0.isComplete }
            let coverage: String? = kind == .answer ? "依据本次本地检索命中的片段回答，不表示已检查全部历史。" :
                (incomplete ? "依据已完成且在本次上下文容量内的录音片段生成，未覆盖全部录音。" : nil)
            var seenTags: Set<String> = []
            let citedTags = result.citations.filter { seenTags.insert($0).inserted }
            let review = AIReview(kind: kind, day: day, title: result.title, body: body,
                                  citations: citedTags.compactMap { lookup[$0] }, coverageNote: coverage, inputClipIDs: inputIDs)
            let oldReviews = reviews, oldMemories = memories
            reviews.append(review)
            for fact in result.memories ?? [] where !fact.text.isEmpty && !fact.citations.isEmpty && fact.citations.allSatisfy({ lookup[$0] != nil }) {
                if !memories.contains(where: { $0.text == fact.text }) {
                    // Suggestions remain inactive until the user chooses to activate them.
                    memories.append(MemoryFact(text: fact.text, isActive: false,
                        sourceCitations: fact.citations.compactMap { lookup[$0] }, inputClipIDs: inputIDs))
                }
            }
            do { try persist() } catch { reviews = oldReviews; memories = oldMemories; throw error }
            if kind == .answer { answer = review }
            status = "\(kind.title)已保存"
        } catch {
            guard remoteGeneration == generation else { return }
            if isCancellation(error) { status = "AI 处理已取消，本地记录已保留" } else { report(error) }
        }
    }

    private func runDayReview(day: Date, kind: AIReview.Kind, sources: [SourceCitation], requiresCharging: Bool) async {
        guard !isAIProcessing else { lastError = "已有 AI 任务正在执行。"; return }
        guard settings.remoteAIEnabled else { lastError = "请先明确开启远程 AI；没有发送任何文字。"; return }
        guard let disk, !sources.isEmpty else { lastError = "还没有可用转写，未发送请求。"; return }
        let generation = UUID(); remoteGeneration = generation
        isAIProcessing = true; lastError = nil
        var powerObserver: NSObjectProtocol?
        if requiresCharging {
            UIDevice.current.isBatteryMonitoringEnabled = true
            powerObserver = NotificationCenter.default.addObserver(forName: UIDevice.batteryStateDidChangeNotification,
                                                                   object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    let power = UIDevice.current.batteryState
                    if power != .charging && power != .full { self?.dayReviewTask?.cancel() }
                }
            }
        }
        defer {
            if let powerObserver { NotificationCenter.default.removeObserver(powerObserver) }
            if remoteGeneration == generation { isAIProcessing = false; dayReviewTask = nil }
        }
        do {
            guard let key = try IntelligenceKeychain.read(), !key.isEmpty else { throw IntelligenceError.message("未保存 API 密钥。") }
            let configuration = settings
            let pendingCount = clipIndex.values.filter { clip in
                sameDay(clip.startedAt, day) && !documents.contains { $0.clipID == clip.id && $0.isComplete && $0.sourceSHA256 == clip.sha256 }
            }.count
            let times = Dictionary(uniqueKeysWithValues: documents.map { ($0.clipID, $0.startedAt) })
            let pipeline = DayReviewPipeline(disk: disk)
            let call = Task {
                try await pipeline.run(sources: sources, recordedAt: times, day: day, kind: kind,
                    pendingTranscripts: pendingCount, settings: configuration, key: key,
                    gate: { [weak self] in
                        guard let self, self.remoteGeneration == generation, self.settings.remoteAIEnabled,
                              self.settings.apiBaseURL == configuration.apiBaseURL,
                              self.settings.model == configuration.model else { throw CancellationError() }
                        if requiresCharging {
                            let power = UIDevice.current.batteryState
                            guard self.executionAllowed, power == .charging || power == .full else { throw CancellationError() }
                        }
                    }, progress: { [weak self] value in
                        guard let self, self.remoteGeneration == generation else { return }
                        self.reviewProgress = value; self.status = value.message
                    })
            }
            dayReviewTask = call
            let output = try await withTaskCancellationHandler(operation: { try await call.value }, onCancel: { call.cancel() })
            guard remoteGeneration == generation, settings.remoteAIEnabled else { throw CancellationError() }
            let lookup = Dictionary(uniqueKeysWithValues: sources.enumerated().map { (AIContextPlanner.sourceID(index: $0.offset), $0.element) })
            var body = output.reply.body
            for (tag, source) in lookup {
                body = body.replacingOccurrences(of: "[\(tag)]", with:
                    "[\(tag)](daytape://clip/\(source.clipID.uuidString)?offset=\(source.offset))")
            }
            var seen: Set<String> = []
            let citations = output.reply.citations.filter { seen.insert($0).inserted }.compactMap { lookup[$0] }
            let allInputs = Array(Set(sources.map(\.clipID))).sorted { $0.uuidString < $1.uuidString }
            let coverage = "已处理全部 \(output.sourceBlockCount) 个原文块、\(sources.count) 个可用转写片段。" +
                (pendingCount > 0 ? "当天仍有 \(pendingCount) 段录音未完成转写，本回顾暂未覆盖这些录音。" : "覆盖本机已有全部转写；尚未接收的手表录音不在本次输入中。")
            let review = AIReview(kind: kind, day: day, title: output.reply.title, body: body, citations: citations,
                coverageNote: coverage, sourceFingerprint: output.fingerprint, inputClipIDs: allInputs,
                pendingTranscriptCount: pendingCount)
            let oldReviews = reviews, oldMemories = memories
            if let index = reviews.firstIndex(where: { $0.kind == kind && $0.sourceFingerprint == output.fingerprint && sameDay($0.day, day) }) {
                var reused = review; reused.id = reviews[index].id; reused.createdAt = reviews[index].createdAt
                reviews[index] = reused
            } else { reviews.append(review) }
            for fact in output.reply.memories ?? [] where !fact.text.isEmpty && !fact.citations.isEmpty && fact.citations.allSatisfy({ lookup[$0] != nil }) {
                if !memories.contains(where: { $0.text == fact.text }) {
                    memories.append(MemoryFact(text: fact.text, isActive: false,
                        sourceCitations: fact.citations.compactMap { lookup[$0] }, inputClipIDs: allInputs))
                }
            }
            do { try persist() } catch { reviews = oldReviews; memories = oldMemories; throw error }
            status = "\(kind.title)已保存，已完整处理本次全部可用文字"
        } catch {
            guard remoteGeneration == generation else { return }
            if isCancellation(error) { status = "AI 处理已暂停，完成的分块已保存，可继续" } else { report(error) }
        }
    }

    private func changeJob(_ id: UUID, state: TranscriptionJob.State, error: String?) {
        guard let index = jobs.firstIndex(where: { $0.clipID == id }) else { return }
        jobs[index].state = state; jobs[index].error = error; jobs[index].updatedAt = Date()
    }
    private func invalidateAIWork() {
        if isAIProcessing, var progress = reviewProgress, progress.phase != .completed {
            progress.phase = .paused; progress.message = "处理已暂停，完成的分块已保存，可继续。"; progress.updatedAt = Date()
            try? disk?.saveProgress(progress); reviewProgress = progress
        }
        remoteGeneration = UUID(); remoteTask?.cancel(); remoteTask = nil
        dayReviewTask?.cancel(); dayReviewTask = nil; isAIProcessing = false
    }
    private func isCancellation(_ error: Error) -> Bool {
        Task.isCancelled || error is CancellationError ||
            ((error as NSError).domain == NSURLErrorDomain && (error as NSError).code == NSURLErrorCancelled)
    }
    private var connectedToPower: Bool {
        let state = UIDevice.current.batteryState
        return state == .charging || state == .full
    }
    private func transcriptionLocale(_ value: IntelligenceSettings) -> String {
        guard (value.transcriptionBackend ?? .onDevice) == .configuredService else { return value.localeIdentifier }
        let language = (value.remoteASRLanguage ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return language.isEmpty ? "auto" : language
    }
    private func backendIdentifier(_ value: IntelligenceSettings) -> String {
        guard (value.transcriptionBackend ?? .onDevice) == .configuredService else { return "local:" + value.localeIdentifier }
        let parts = [value.remoteASRBaseURL ?? "", value.remoteASRModel ?? "", value.remoteASRLanguage ?? "", value.remoteASRResponseFormat ?? "verbose_json"]
        let data = (try? JSONEncoder().encode(parts)) ?? Data()
        return "service:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private func upsert(_ document: TranscriptDocument) {
        if let index = documents.firstIndex(where: { $0.clipID == document.clipID }) { documents[index] = document }
        else { documents.append(document); documents.sort { $0.startedAt < $1.startedAt } }
    }
    private func commitTranscript(_ document: TranscriptDocument) throws {
        if documents.contains(where: { $0.clipID == document.clipID }) { try updateDocument(document) }
        else { try disk?.save(document); upsert(document) }
    }
    private func persist() throws {
        guard !deletionValidationFailed else { throw IntelligenceError.message("删除记录暂时无法验证，智能记录已隐藏，请稍后重试。") }
        guard let disk else { throw IntelligenceError.message("本地智能记录存储不可用。") }
        try disk.save(IntelligenceSnapshot(settings: settings, jobs: jobs, reviews: reviews, memories: memories,
                                           excludedClipIDs: Array(excludedClipIDs), transcriptionPaused: queuePaused,
                                           automaticReviewAttempts: automaticReviewAttempts))
    }
    private func createProcessingHold(_ id: UUID) throws {
        let url = store.root.appendingPathComponent(id.uuidString + ".processing-hold")
        if !FileManager.default.fileExists(atPath: url.path) { try Data().write(to: url, options: .atomic) }
    }
    private func removeProcessingHold(_ id: UUID) throws {
        let url = store.root.appendingPathComponent(id.uuidString + ".processing-hold")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    private func sameDay(_ a: Date, _ b: Date) -> Bool { DailySchedule().calendar.isDate(a, inSameDayAs: b) }
    private func report(_ error: Error) { lastError = error.localizedDescription; status = "需要处理" }

    private func reviewAllowedAfterDeletion(_ value: AIReview) -> Bool {
        guard !excludedClipIDs.isEmpty else { return true }
        guard let inputs = value.inputClipIDs else { return false }
        return excludedClipIDs.isDisjoint(with: inputs) && !value.citations.contains { excludedClipIDs.contains($0.clipID) }
    }
    private func memoryAllowedAfterDeletion(_ value: MemoryFact) -> Bool {
        guard !excludedClipIDs.isEmpty else { return true }
        if value.sourceCitations.contains(where: { excludedClipIDs.contains($0.clipID) }) { return false }
        if let inputs = value.inputClipIDs { return excludedClipIDs.isDisjoint(with: inputs) }
        return value.sourceCitations.isEmpty // A manually entered fact has no recording dependency.
    }
    private func filterDeletedContent() {
        guard !excludedClipIDs.isEmpty else { return }
        if let activeClipID, excludedClipIDs.contains(activeClipID) {
            processTask?.cancel(); speech.cancel(); remoteSpeech.cancel()
        }
        let keptDocuments = documents.filter { !excludedClipIDs.contains($0.clipID) }
        let keptReviews = reviews.filter { reviewAllowedAfterDeletion($0) }
        let keptMemories = memories.filter { memoryAllowedAfterDeletion($0) }
        if keptDocuments.count != documents.count { documents = keptDocuments; searchGeneration = UUID() }
        if keptReviews.count != reviews.count { reviews = keptReviews }
        if keptMemories.count != memories.count { memories = keptMemories }
        jobs.removeAll { excludedClipIDs.contains($0.clipID) }
        searchResults.removeAll { excludedClipIDs.contains($0.clipID) }
        if let current = answer, !reviewAllowedAfterDeletion(current) { answer = nil }
    }
    /// The authoritative tombstone remains until all unrelated modules have independently
    /// reconciled it. Physical deletion errors never unhide the filtered records.
    private func reconcileDeletedContent() throws {
        let targets = excludedClipIDs.subtracting(reconciledDeletionIDs).union(pendingDeletionIDs)
        guard !targets.isEmpty else { pendingDeletionCount = 0; deletionCleanupError = nil; return }
        pendingDeletionIDs.formUnion(targets); pendingDeletionCount = pendingDeletionIDs.count
        guard let disk else {
            let error = IntelligenceError.message("相关文字已隐藏，仍有 \(pendingDeletionCount) 项等待本机存储恢复后清理。")
            deletionCleanupError = error.localizedDescription; throw error
        }
        var firstError: Error?, stateSaved = true
        do { try persist() } catch { stateSaved = false; firstError = error }
        var rawPending: Set<UUID> = []
        do { try store.purgeDeletedAudio(only: targets) }
        catch {
            if firstError == nil { firstError = error }
            rawPending = (try? store.pendingDeletedAudioIDs(only: targets)) ?? targets
        }
        for id in targets {
            var completed = stateSaved && !rawPending.contains(id)
            do { try disk.deleteDocument(id) } catch { completed = false; if firstError == nil { firstError = error } }
            do { try disk.deleteAICaches(containing: id) } catch { completed = false; if firstError == nil { firstError = error } }
            do { try removeProcessingHold(id) } catch { completed = false; if firstError == nil { firstError = error } }
            if completed { pendingDeletionIDs.remove(id); reconciledDeletionIDs.insert(id) }
        }
        reviewProgress = nil
        pendingDeletionCount = pendingDeletionIDs.count
        if let firstError { deletionCleanupError = firstError.localizedDescription; throw firstError }
        deletionCleanupError = nil
    }
}
