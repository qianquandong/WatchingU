import Foundation
import Combine
import AVFoundation
import CoreML
import FluidAudio
import UIKit

private struct LocalVoiceProfile: Codable, Sendable {
    var embedding: [Float]
    var createdAt: Date
    var modelVersion = "FluidAudio-0.12.4-WeSpeaker"
}

private struct SpeakerSpan: Sendable {
    var start: Double
    var end: Double
    var speakerID: String
    var label: String
}

private actor VoiceIdentityEngine {
    let root: URL
    private var manager: DiarizerManager?
    private var profile: LocalVoiceProfile?
    private var enrollment: [[Float]] = []
    private var sessionID: UUID?
    init(root: URL) {
        self.root = root
        if let data = try? Data(contentsOf: root.appendingPathComponent("voice-profile.json")) {
            profile = try? JSONDecoder().decode(LocalVoiceProfile.self, from: data)
        }
    }
    func prepareModels() async throws {
        try Task.checkCancellation()
        guard manager == nil else { return }
        let configuration = MLModelConfiguration()
        #if targetEnvironment(simulator)
        configuration.computeUnits = .cpuOnly
        #else
        configuration.computeUnits = .cpuAndNeuralEngine
        #endif
        let models = try await DiarizerModels.downloadIfNeeded(configuration: configuration)
        try Task.checkCancellation()
        let next = DiarizerManager(); next.initialize(models: models)
        manager = next
    }
    private func samples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.length > 0, file.length <= AVAudioFramePosition(file.processingFormat.sampleRate * 180),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: format),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(ceil(Double(file.length) * 16000 / file.processingFormat.sampleRate)) + 4096) else {
            throw IntelligenceError.message("这段音频无法用于声音识别。")
        }
        try file.read(into: input)
        var provided = false; var error: NSError?
        let result = converter.convert(to: output, error: &error) { _, status in
            if provided { status.pointee = .endOfStream; return nil }
            provided = true; status.pointee = .haveData; return input
        }
        if let error = error { throw error }
        guard result != .error, let channel = output.floatChannelData?.pointee, output.frameLength >= 16000 else {
            throw IntelligenceError.message("需要至少一秒清晰人声。")
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
    func enroll(url: URL) async throws -> Int {
        try await prepareModels()
        try Task.checkCancellation()
        guard let manager = manager else { throw IntelligenceError.message("声音模型尚未准备好。") }
        let audio = try samples(url)
        let validation = manager.validateAudio(audio)
        guard validation.isValid else { throw IntelligenceError.message("请在安静处独自朗读，再录一次。") }
        let embedding = try manager.extractSpeakerEmbedding(from: audio)
        try Task.checkCancellation()
        guard manager.validateEmbedding(embedding) else { throw IntelligenceError.message("没有取得可用声纹，请重新录制。") }
        enrollment.append(embedding)
        if enrollment.count >= 3 {
            var mean = [Float](repeating: 0, count: embedding.count)
            for vector in enrollment { for index in mean.indices { mean[index] += vector[index] / Float(enrollment.count) } }
            let norm = sqrt(mean.reduce(Float(0)) { $0 + $1 * $1 })
            guard norm > 0 else { throw IntelligenceError.message("声纹资料无效，请重试。") }
            mean = mean.map { $0 / norm }
            let next = LocalVoiceProfile(embedding: mean, createdAt: Date())
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let path = root.appendingPathComponent("voice-profile.json")
            try JSONEncoder().encode(next).write(to: path, options: .atomic)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: path.path)
            profile = next; enrollment.removeAll(); sessionID = nil
            return 3
        }
        return enrollment.count
    }
    func removeProfile() throws {
        let path = root.appendingPathComponent("voice-profile.json")
        if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
        profile = nil; enrollment.removeAll(); sessionID = nil
        manager?.speakerManager.reset()
    }
    func identify(url: URL, session: UUID) async throws -> [SpeakerSpan] {
        try await prepareModels(); try Task.checkCancellation()
        guard let manager = manager else { throw IntelligenceError.message("声音模型尚未准备好。") }
        if sessionID != session {
            manager.speakerManager.reset()
            if let profile = profile {
                manager.initializeKnownSpeakers([Speaker(id: "me", name: "我", currentEmbedding: profile.embedding, isPermanent: true)])
            }
            sessionID = session
        }
        let audio = try samples(url)
        var detected: [TimedSpeakerSegment] = []
        for start in stride(from: 0, to: audio.count, by: 160_000) {
            try Task.checkCancellation()
            let end = min(audio.count, start + 160_000)
            let result = try manager.performCompleteDiarization(audio[start..<end], sampleRate: 16000, atTime: Double(start) / 16000)
            detected.append(contentsOf: result.segments)
        }
        try Task.checkCancellation()
        return detected.map { span in
            let similarity = profile.flatMap {
                IntelligenceMath.cosineSimilarity($0.embedding.map(Double.init), span.embedding.map(Double.init))
            }
            let isMe = similarity.map { $0 >= 0.75 } ?? false
            return SpeakerSpan(start: Double(span.startTimeSeconds), end: Double(span.endTimeSeconds),
                               speakerID: isMe ? "me" : span.speakerId,
                               label: isMe ? "可能是我" : (span.speakerId == "me" ? "未确认说话人" : "说话人 " + String(span.speakerId.suffix(5))))
        }
    }
}

@MainActor
final class VoiceIdentityService: ObservableObject {
    @Published private(set) var status = "声音识别未开启"
    @Published private(set) var errorText: String?
    @Published private(set) var isBusy = false
    @Published private(set) var recording = false
    @Published private(set) var samplesCollected = 0
    @Published private(set) var enrolled = false
    @Published var enabled = false
    private let engine: VoiceIdentityEngine
    private let store: ClipStore
    private let root: URL
    private var recorder: AVAudioRecorder?
    private var recordingTask: Task<Void, Never>?
    private var work: Task<Void, Never>?
    private var enrollmentGeneration = UUID()
    private var enrollmentAuthorizing = false
    init(store: ClipStore) {
        self.store = store; root = store.root.appendingPathComponent("VoiceIdentity", isDirectory: true)
        engine = VoiceIdentityEngine(root: root)
        enrolled = FileManager.default.fileExists(atPath: root.appendingPathComponent("voice-profile.json").path)
        enabled = UserDefaults.standard.bool(forKey: "daytape.voice.enabled")
    }
    func prepare() async {
        guard !isBusy else { return }; isBusy = true; errorText = nil
        defer { isBusy = false }
        status = "正在下载并准备本机声音模型…"
        do { try await engine.prepareModels(); enabled = true; UserDefaults.standard.set(true, forKey: "daytape.voice.enabled"); status = "本机声音模型已就绪" }
        catch { errorText = error.localizedDescription; status = "模型准备未完成，可以重试" }
    }
    func recordEnrollment() async {
        guard !recording, !isBusy, !enrollmentAuthorizing,
              UIApplication.shared.applicationState == .active else { return }
        let generation = UUID(); enrollmentGeneration = generation; enrollmentAuthorizing = true
        defer { if enrollmentGeneration == generation { enrollmentAuthorizing = false } }
        let allowed = await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard enrollmentGeneration == generation, UIApplication.shared.applicationState == .active,
              !recording, !isBusy else { return }
        guard allowed else { errorText = "请在系统设置中允许麦克风，才能录制本人声纹。"; return }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let session = AVAudioSession.sharedInstance(); try session.setCategory(.record, mode: .measurement)
            try session.setActive(true)
            let path = root.appendingPathComponent("enrollment.m4a")
            let next = try AVAudioRecorder(url: path, settings: [AVFormatIDKey:kAudioFormatMPEG4AAC,
                                                               AVSampleRateKey:16000, AVNumberOfChannelsKey:1, AVEncoderBitRateKey:64000])
            guard next.record() else { throw IntelligenceError.message("麦克风未开始录制，请重试。") }
            recorder = next; recording = true; status = "请独自朗读 15 秒（第 \(samplesCollected + 1)/3 段）"
            recordingTask = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 15_000_000_000); await self?.finishEnrollment(path, generation: generation) }
                catch { self?.cancelEnrollment() }
            }
        } catch { errorText = error.localizedDescription; cancelEnrollment() }
    }
    private func finishEnrollment(_ path: URL, generation: UUID) async {
        guard enrollmentGeneration == generation else { return }
        recorder?.stop(); recorder = nil; recording = false; isBusy = true
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        defer { isBusy = false; try? FileManager.default.removeItem(at: path) }
        do {
            let count = try await engine.enroll(url: path)
            guard enrollmentGeneration == generation else { return }
            samplesCollected = count
            if samplesCollected == 3 { enrolled = true; status = "本人声纹已保存到本机" }
            else { status = "已采集 \(samplesCollected)/3 段，请再录一段" }
        } catch { errorText = error.localizedDescription; status = "这次声纹采集未完成" }
    }
    func cancelEnrollment() {
        enrollmentGeneration = UUID(); enrollmentAuthorizing = false
        recorder?.stop(); recorder = nil; recording = false; recordingTask?.cancel(); recordingTask = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        try? FileManager.default.removeItem(at: root.appendingPathComponent("enrollment.m4a"))
        if !isBusy { status = "声纹录制已停止" }
    }
    func removeProfile() async {
        cancelEnrollment()
        do { try await engine.removeProfile(); enrolled = false; samplesCollected = 0; status = "本人声纹已删除" }
        catch { errorText = error.localizedDescription }
    }
    func identify(clip: Clip, intelligence: IntelligenceController) {
        guard enabled, !isBusy, let document = intelligence.documents.first(where: { $0.clipID == clip.id }),
              document.isComplete, store.retainAudio(clip.id) else { errorText = "请先完成本地转写，并保留原声。"; return }
        isBusy = true; errorText = nil; status = "正在本机识别说话人…"
        work = Task(priority: .utility) { [weak self] in
            guard let self = self else { return }
            defer { self.store.releaseAudio(clip.id); self.isBusy = false; self.work = nil }
            do {
                let spans = try await self.engine.identify(url: self.store.audioURL(clip.id), session: clip.sessionID)
                try Task.checkCancellation()
                var next = document
                for index in next.segments.indices {
                    let segment = next.segments[index]
                    let end = segment.offset + segment.duration
                    let matching = spans.map { ($0, max(0, min(end, $0.end) - max(segment.offset, $0.start))) }
                        .max { $0.1 < $1.1 }
                    if let (span, overlap) = matching, overlap > 0 {
                        next.segments[index].speakerID = span.speakerID; next.segments[index].speakerLabel = span.label
                    }
                }
                try intelligence.updateDocument(next); self.status = "说话人标签已更新，可手动修正"
            } catch is CancellationError { self.status = "声音识别已暂停" }
            catch { self.errorText = error.localizedDescription; self.status = "声音识别未完成" }
        }
    }
    func pause() { work?.cancel(); cancelEnrollment() }
}
