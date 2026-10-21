import AVFoundation
import Foundation

/// The capture engine stays running at segment boundaries. Only the encoded output file rolls.
/// PCM buffers are copied out of the audio callback; encoding and disk I/O run on a serial queue.
final class CaptureWriter {
    private let queue = DispatchQueue(label: "daytape.writer", qos: .userInitiated)
    private let backlogLock = NSLock()
    private var queued = 0
    private var failed = false
    private var accepting = true
    private let deadline: Date?
    private let onDeadline: () -> Void
    private let store: ClipStore
    private let sessionID: UUID
    private var file: AVAudioFile?
    private var draft: CaptureDraft?
    private var converter: AVAudioConverter?
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: 16000, channels: 1, interleaved: false)!
    private var frames: AVAudioFramePosition = 0
    private var unreported: Double = 0
    let onSealed: (Clip) -> Void
    let onFailure: (Error) -> Void
    let onFrames: (Double) -> Void

    init(store: ClipStore, sessionID: UUID, deadline: Date? = nil, onDeadline: @escaping () -> Void = {}, onSealed: @escaping (Clip) -> Void,
         onFailure: @escaping (Error) -> Void, onFrames: @escaping (Double) -> Void) {
        self.store = store; self.sessionID = sessionID
        self.deadline = deadline; self.onDeadline = onDeadline
        self.onSealed = onSealed; self.onFailure = onFailure; self.onFrames = onFrames
    }
    func append(_ input: AVAudioPCMBuffer, at date: Date) {
        backlogLock.lock()
        guard accepting else { backlogLock.unlock(); return }
        if let deadline = deadline, date >= deadline {
            accepting = false; backlogLock.unlock(); onDeadline(); return
        }
        if queued >= 32 {
            accepting = false; backlogLock.unlock()
            onFailure(ArchiveError.backlog); return
        }
        queued += 1
        guard let copy = Self.copy(input) else {
            queued -= 1; accepting = false; backlogLock.unlock()
            onFailure(ArchiveError.encoding); return
        }
        queue.async {
            defer { self.backlogLock.lock(); self.queued -= 1; self.backlogLock.unlock() }
            guard !self.failed else { return }
            do { try self.consume(copy, at: date) }
            catch { self.failed = true; self.onFailure(error) }
        }
        // Serialize producer handoff with finish(), so no buffer can be queued after finalization.
        backlogLock.unlock()
    }
    private static func copy(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else { return nil }
        copy.frameLength = source.frameLength
        let from = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: source.audioBufferList))
        let to = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard from.count == to.count else { return nil }
        for index in 0..<from.count {
            guard let src = from[index].mData, let dst = to[index].mData else { return nil }
            guard to[index].mDataByteSize >= from[index].mDataByteSize else { return nil }
            memcpy(dst, src, Int(from[index].mDataByteSize))
        }
        return copy
    }
    private func consume(_ input: AVAudioPCMBuffer, at date: Date) throws {
        if converter == nil { converter = AVAudioConverter(from: input.format, to: outputFormat) }
        guard let converter = converter else { throw ArchiveError.encoding }
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 16000 / input.format.sampleRate)) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { throw ArchiveError.encoding }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, flag in
            if supplied { flag.pointee = .noDataNow; return nil }
            supplied = true; flag.pointee = .haveData; return input
        }
        if let error = conversionError { throw error }
        guard status != .error else { throw ArchiveError.encoding }
        if output.frameLength > 0 { try write(output, at: date) }
    }
    private func open(at date: Date) throws {
        try store.ensureBudget()
        let draft = CaptureDraft(id: UUID(), sessionID: sessionID, startedAt: date)
        try store.writeDraft(draft)
        self.draft = draft; frames = 0
        file = try AVAudioFile(forWriting: store.partURL(draft.id), settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 24000
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
    }
    private func write(_ buffer: AVAudioPCMBuffer, at date: Date) throws {
        if let deadline = deadline, file == nil && date >= deadline { return }
        if file == nil { try open(at: date) }
        guard file != nil else { throw ArchiveError.encoding }
        if let deadline = deadline, let start = draft?.startedAt {
            let remaining = max(0, floor(deadline.timeIntervalSince(start) * 16000) - Double(frames))
            buffer.frameLength = min(buffer.frameLength, AVAudioFrameCount(min(remaining, Double(buffer.frameLength))))
            if buffer.frameLength == 0 { return }
        }
        // Do not hold a local strong reference to AVAudioFile across closeSegment().
        // Its deinitializer must flush the encoder before the file is hashed.
        try file?.write(from: buffer)
        frames += AVAudioFramePosition(buffer.frameLength)
        unreported += Double(buffer.frameLength) / 16000
        if unreported >= 2 { onFrames(unreported); unreported = 0 }
        if frames >= 60 * 16000 { try closeSegment() }
    }
    private func closeSegment() throws {
        guard let draft = draft else { return }
        file = nil // finalizes the M4A container before hashing or transmitting it
        let duration = Double(frames) / 16000
        self.draft = nil; frames = 0
        if duration > 0 { onSealed(try store.seal(draft, duration: duration)) }
    }
    func finish(_ completion: @escaping (Error?) -> Void) {
        backlogLock.lock(); accepting = false
        queue.async {
            do {
                // Drain converter latency once, at capture end, not at each file boundary.
                if let converter = self.converter,
                   let tail = AVAudioPCMBuffer(pcmFormat: self.outputFormat, frameCapacity: 4096) {
                    for _ in 0..<16 {
                        tail.frameLength = 0
                        var error: NSError?
                        let result = converter.convert(to: tail, error: &error) { _, status in
                            status.pointee = .endOfStream; return nil
                        }
                        if let error = error { throw error }
                        if result == .error { throw ArchiveError.encoding }
                        if tail.frameLength > 0 && !self.failed { try self.write(tail, at: Date()) }
                        if result == .endOfStream || result == .inputRanDry || tail.frameLength == 0 { break }
                    }
                }
                try self.closeSegment()
                completion(nil)
            } catch { self.file = nil; completion(error) }
        }
        backlogLock.unlock()
    }
}
