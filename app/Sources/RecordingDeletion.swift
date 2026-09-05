import Foundation

enum RecordingDeletion: String, CaseIterable, Identifiable {
    case audio, transcript, both
    var id: String { rawValue }
    var title: String {
        switch self {
        case .audio: return "Audio only"
        case .transcript: return "Transcript only"
        case .both: return "Audio and transcript"
        }
    }
    var explanation: String {
        switch self {
        case .audio: return "Move both audio tracks to Trash. Keep the transcript and call in your library."
        case .transcript: return "Move the transcript and saved summary to Trash. Keep the audio and call in your library."
        case .both: return "Move the audio, transcript, and saved summary to Trash and remove this call from your library."
        }
    }

    func files(id: String, wav: String, directory: URL) throws -> [URL] {
        // Metadata is read from disk. Never let a malformed filename target
        // another call, a directory, or a path outside the recording library.
        guard !id.isEmpty, id != ".", id != "..", !id.contains("/"),
              wav == id + ".wav" else {
            throw NSError(domain: "Scribebot", code: 1, userInfo: [NSLocalizedDescriptionKey: "This call has invalid filenames and cannot be deleted safely."])
        }
        var names: [String] = []
        if self != .transcript { names += [wav, id + "-you.wav"] }
        if self != .audio {
            names += [id + ".txt", id + ".summary.md"]
            // Each template caches its own summary, so deleting a transcript
            // has to take all of them - otherwise a "deleted" call leaves its
            // Standup and Interview summaries sitting in the folder.
            let siblings = (try? FileManager.default
                .contentsOfDirectory(atPath: directory.path)) ?? []
            names += siblings.filter {
                $0.hasPrefix(id + ".summary.") && $0.hasSuffix(".md")
                    && $0 != id + ".summary.md"
            }.sorted()
        }
        // Metadata goes last so a partially completed operation stays visible.
        if self == .both { names.append(id + ".json") }
        return names.map { directory.appendingPathComponent($0) }
    }

    func perform(id: String, wav: String, directory: URL,
                 moveToTrash: (URL) throws -> Void) throws {
        let files = try files(id: id, wav: wav, directory: directory)
        let fm = FileManager.default
        // Validate every target before moving any of them.
        for file in files where fm.fileExists(atPath: file.path) {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw NSError(domain: "Scribebot", code: 2, userInfo: [NSLocalizedDescriptionKey: "An unexpected file was found. Nothing else will be moved to Trash."])
            }
        }
        for file in files where fm.fileExists(atPath: file.path) {
            try moveToTrash(file)
        }
    }
}
