import Foundation

@MainActor
enum ArchiveExport {
    struct Options { var audio = true; var transcripts = true; var reviews = true; var context = true }
    static func make(clips: [Clip], intelligence: IntelligenceController, store: ClipStore,
                     options: Options = Options()) async throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DayTape-export-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
        let destination = directory.appendingPathComponent("DayTape.zip")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        var entries: [StoredZIP.Entry] = []
        var pins: [UUID] = []
        var succeeded = false
        defer {
            pins.forEach { store.releaseAudio($0) }
            if !succeeded { try? FileManager.default.removeItem(at: directory) }
        }
        func append(_ data: Data, name: String) throws {
            let url = directory.appendingPathComponent(UUID().uuidString)
            try data.write(to: url, options: .atomic)
            entries.append(StoredZIP.Entry(name: name, source: url))
        }
        try append(encoder.encode(clips), name: "manifest.json")
        let context = try RecordingContextStore(root: store.root)
        try context.resolveMarks(clips: clips)
        let ids = Set(clips.map(\.id))
        if options.context {
            try append(encoder.encode(try context.marks().filter { $0.clipID.map(ids.contains) == true }), name: "marks.json")
        }
        for clip in clips {
            try Task.checkCancellation()
            let prefix = "recordings/" + clip.id.uuidString
            if options.audio, store.hasLocalAudio(clip.id) {
                guard store.retainAudio(clip.id) else { throw ArchiveError.encoding }
                pins.append(clip.id)
                entries.append(StoredZIP.Entry(name: prefix + ".m4a", source: store.audioURL(clip.id)))
            }
            if options.transcripts, let document = intelligence.documents.first(where: { $0.clipID == clip.id }) {
                try append(encoder.encode(document), name: prefix + ".json")
                let text = document.segments.map { segment in
                    let clock = String(format: "%02d:%02d", Int(segment.offset) / 60, Int(segment.offset) % 60)
                    return "[\(clock)] \(segment.speakerLabel.map { $0 + ": " } ?? "")\(segment.text)"
                }.joined(separator: "\n")
                try append(Data(text.utf8), name: prefix + ".txt")
            }
            if options.context {
                if let place = try context.location(for: clip) { try append(encoder.encode(place), name: prefix + ".location.json") }
                if let health = try context.health(for: clip.id) { try append(encoder.encode(health), name: prefix + ".health.json") }
            }
        }
        if options.reviews {
            for review in intelligence.reviews where ArchiveScopePolicy.permits(review.inputClipIDs, within: ids) {
                try append(encoder.encode(review), name: "reviews/" + review.id.uuidString + ".json")
                try append(Data(("# " + review.title + "\n\n" + review.body).utf8), name: "reviews/" + review.id.uuidString + ".md")
            }
            let memories = intelligence.memories.filter { ArchiveScopePolicy.permits($0.inputClipIDs, within: ids) }
            try append(encoder.encode(memories), name: "memories.json")
        }
        // The archive clearly describes missing original audio rather than inventing a local copy.
        let missing = clips.filter { !store.hasLocalAudio($0.id) }.map { $0.id.uuidString }
        if !missing.isEmpty { try append(Data(("以下原声仅在云端，未包含在 ZIP：\n" + missing.joined(separator: "\n")).utf8), name: "missing-audio.txt") }
        let frozen = entries
        do {
            let writer = Task.detached(priority: .utility) { try StoredZIP.write(entries: frozen, to: destination) }
            try await withTaskCancellationHandler(operation: { try await writer.value }, onCancel: { writer.cancel() })
            succeeded = true
            return destination
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
    static func audio(clip: Clip, store: ClipStore) async throws -> URL {
        guard store.retainAudio(clip.id) else { throw ArchiveError.encoding }
        defer { store.releaseAudio(clip.id) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DayTape-export-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(clip.fileName)
        do {
            let source = store.audioURL(clip.id)
            try await Task.detached(priority: .utility) { try FileManager.default.copyItem(at: source, to: target) }.value
            try Task.checkCancellation()
            return target
        } catch { try? FileManager.default.removeItem(at: folder); throw error }
    }
    static func discard(_ url: URL) {
        let directory = url.deletingLastPathComponent()
        guard directory.lastPathComponent.hasPrefix("DayTape-export-") else { return }
        try? FileManager.default.removeItem(at: directory)
    }
}
