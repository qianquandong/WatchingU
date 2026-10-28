import Foundation
import Speech
import AVFoundation

/// One cancellable on-device recognition at a time; never falls back to Apple's servers.
@MainActor
final class LocalSpeechTranscriber {
    private var recognition: SFSpeechRecognitionTask?
    private var continuation: CheckedContinuation<[TranscriptSegment], Error>?
    private var timeout: Task<Void, Never>?
    private var export: AVAssetExportSession?
    private var recognitionID: UUID?

    static var supportedLocales: [Locale] {
        SFSpeechRecognizer.supportedLocales().sorted { $0.identifier < $1.identifier }
    }

    func authorize() async throws {
        let current = SFSpeechRecognizer.authorizationStatus()
        let result: SFSpeechRecognizerAuthorizationStatus
        if current == .notDetermined {
            result = await withCheckedContinuation { pending in
                SFSpeechRecognizer.requestAuthorization { pending.resume(returning: $0) }
            }
        } else { result = current }
        guard result == .authorized else {
            throw IntelligenceError.message("请在系统设置中允许语音识别；音频仅在本机转写。")
        }
    }

    func cancel() {
        export?.cancelExport()
        if let id = recognitionID { finish(.failure(CancellationError()), id: id) }
    }

    func transcribe(source: URL, offset: Double, duration: Double,
                    localeIdentifier: String) async throws -> [TranscriptSegment] {
        try Task.checkCancellation()
        guard duration > 0, duration <= 55 else {
            throw IntelligenceError.message("本地转写窗口必须在 55 秒以内。")
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)),
              recognizer.supportsOnDeviceRecognition else {
            throw IntelligenceError.message("此设备未提供 \(localeIdentifier) 的本地语音模型；不会转为云端识别。请换一种已安装语言。")
        }
        guard recognizer.isAvailable else {
            throw IntelligenceError.message("本地语音识别暂不可用，请稍后重试。")
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let asset = AVURLAsset(url: source)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw IntelligenceError.message("无法读取这段音频，原文件已保留。")
        }
        exporter.outputURL = temporary; exporter.outputFileType = .m4a
        exporter.timeRange = CMTimeRange(start: CMTime(seconds: offset, preferredTimescale: 600),
                                        duration: CMTime(seconds: duration, preferredTimescale: 600))
        export = exporter
        await exporter.export()
        export = nil
        try Task.checkCancellation()
        guard exporter.status == .completed else {
            throw exporter.error ?? IntelligenceError.message("准备本地转写音频失败，原文件已保留。")
        }
        let request = SFSpeechURLRecognitionRequest(url: temporary)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        request.addsPunctuation = true
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { pending in
                let id = UUID()
                recognitionID = id
                continuation = pending
                recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
                    Task { @MainActor in
                        guard let self else { return }
                        if let result, result.isFinal {
                            self.finish(.success(Self.segments(result.bestTranscription, baseOffset: offset,
                                                               maximumDuration: duration)), id: id)
                        } else if let error { self.finish(.failure(error), id: id) }
                    }
                }
                timeout = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 120_000_000_000) }
                    catch { return }
                    self?.finish(.failure(IntelligenceError.message("本地转写超时，已保存完成进度，可重试。")), id: id)
                }
            }
        }, onCancel: { [weak self] in Task { @MainActor in self?.cancel() } })
    }

    private func finish(_ result: Result<[TranscriptSegment], Error>, id: UUID) {
        guard recognitionID == id, let pending = continuation else { return }
        recognitionID = nil; continuation = nil; timeout?.cancel(); timeout = nil
        recognition?.cancel(); recognition = nil
        pending.resume(with: result)
    }

    private static func segments(_ transcription: SFTranscription, baseOffset: Double,
                                 maximumDuration: Double) -> [TranscriptSegment] {
        let words = transcription.segments
        guard !words.isEmpty else {
            return transcription.formattedString.isEmpty ? [] : [TranscriptSegment(offset: baseOffset,
                duration: maximumDuration, text: transcription.formattedString)]
        }
        let text = transcription.formattedString as NSString
        var result: [TranscriptSegment] = [], start = 0
        func append(_ end: Int) {
            let first = words[start], last = words[end]
            let range = NSUnionRange(first.substringRange, last.substringRange)
            guard NSMaxRange(range) <= text.length else { return }
            result.append(TranscriptSegment(offset: baseOffset + first.timestamp,
                duration: max(0, min(maximumDuration, last.timestamp + last.duration) - first.timestamp),
                text: text.substring(with: range)))
        }
        for index in words.indices {
            let last = index == words.count - 1
            let long = words[index].timestamp + words[index].duration - words[start].timestamp >= 12
            let gap = !last && words[index + 1].timestamp - words[index].timestamp - words[index].duration > 1.2
            if last || long || gap { append(index); start = index + 1 }
        }
        return result
    }
}
