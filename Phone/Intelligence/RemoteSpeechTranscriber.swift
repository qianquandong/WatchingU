import Foundation
import AVFoundation

@MainActor
final class RemoteSpeechTranscriber {
    private var export: AVAssetExportSession?
    private var session: URLSession?

    static func endpoint(_ input: String) throws -> URL {
        guard let parts = URLComponents(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              let base = parts.url else { throw IntelligenceError.message("转写服务需要不含密码或查询参数的 HTTPS API 地址。") }
        if base.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).hasSuffix("audio/transcriptions") { return base }
        return base.appendingPathComponent("audio/transcriptions")
    }

    func cancel() { export?.cancelExport(); session?.invalidateAndCancel(); session = nil }

    func transcribe(source: URL, offset: Double, duration: Double, settings: IntelligenceSettings,
                    key: String, gate: @escaping @MainActor () throws -> Void) async throws -> [TranscriptSegment] {
        guard settings.transcriptionBackend == .configuredService, settings.remoteASRSharingEnabled == true else {
            throw IntelligenceError.message("尚未允许向转写服务分享录音；没有发送音频。")
        }
        try Task.checkCancellation(); try gate()
        guard duration > 0, duration <= 55 else { throw IntelligenceError.message("远程转写窗口必须在 55 秒以内。") }
        let model = (settings.remoteASRModel ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !model.isEmpty, !model.contains(where: \.isNewline) else {
            throw IntelligenceError.message("请先保存转写服务的独立密钥和模型名称。")
        }
        let language = (settings.remoteASRLanguage ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !language.contains(where: \.isNewline) else { throw IntelligenceError.message("转写语言格式不正确。") }
        let endpoint = try Self.endpoint(settings.remoteASRBaseURL ?? "")
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let asset = AVURLAsset(url: source)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw IntelligenceError.message("无法准备远程转写窗口，原声已保留。")
        }
        exporter.outputURL = temporary; exporter.outputFileType = .m4a
        exporter.timeRange = CMTimeRange(start: CMTime(seconds: offset, preferredTimescale: 600),
                                        duration: CMTime(seconds: duration, preferredTimescale: 600))
        export = exporter; await exporter.export(); export = nil
        try Task.checkCancellation(); try gate()
        guard exporter.status == .completed else { throw exporter.error ?? IntelligenceError.message("准备转写音频失败。") }
        let audio = try Data(contentsOf: temporary)
        guard audio.count <= 8 * 1024 * 1024 else { throw IntelligenceError.message("单个转写窗口超过 8 MB，未上传。") }
        let boundary = "DayTape-" + UUID().uuidString
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", model)
        field("response_format", settings.remoteASRResponseFormat == "json" ? "json" : "verbose_json")
        if !language.isEmpty { field("language", language) }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"recording.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n".utf8))
        body.append(audio); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"; request.timeoutInterval = 150
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=" + boundary, forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForResource = 180
        let network = URLSession(configuration: configuration, delegate: ConsentBoundSessionDelegate(origin: endpoint), delegateQueue: nil); session = network
        defer { network.invalidateAndCancel(); session = nil }
        // The request begins only after the current consent is checked, never as a local-ASR fallback.
        try gate(); try Task.checkCancellation()
        let (data, response) = try await network.data(for: request)
        try Task.checkCancellation(); try gate()
        guard let http = response as? HTTPURLResponse else { throw IntelligenceError.message("转写服务未返回 HTTP 响应。") }
        guard (200..<300).contains(http.statusCode) else {
            throw IntelligenceError.message("转写服务返回 HTTP \(http.statusCode)。请检查密钥、模型、响应格式或额度；原声与已完成窗口已保留。")
        }
        guard data.count <= 4 * 1024 * 1024, let result = try? JSONDecoder().decode(ConfiguredSpeechResponse.self, from: data),
              result.text != nil || result.segments != nil else {
            throw IntelligenceError.message("转写服务响应格式无效，未写入虚假转写。需要 JSON text 或 segments。")
        }
        return try result.transcriptSegments(offset: offset, duration: duration)
    }
}
