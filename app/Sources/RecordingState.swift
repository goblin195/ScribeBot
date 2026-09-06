import Foundation
import Darwin

enum RecordingStatus: String, Codable, Sendable {
    case recording, awaitingTranscription, transcribing, complete, partial, failed

    var needsRecovery: Bool { self != .complete }
}

struct Recording: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var startedAt: Date
    var duration: TimeInterval
    var wav: String
    // Optional for old libraries: absence does not mean a legacy recording failed.
    var status: RecordingStatus? = nil
    var failure: String? = nil
    var updatedAt: Date? = nil
    var captureIssue: String? = nil
    var speakerTranscript: SpeakerTranscript? = nil
    var speakerFailure: String? = nil

    var durationText: String {
        let s = Int(duration.rounded())
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct RecordingFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// A library has one recording/finalization owner across app instances. The
/// capture helpers inherit a duplicate on stdin, so an app crash does not make
/// actively written audio available for recovery until the helpers exit too.
final class RecordingLease: @unchecked Sendable {
    private let fd: Int32

    init(directory: URL) throws {
        fd = Darwin.open(directory.appendingPathComponent(".capture.lock").path,
                         O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw RecordingFailure(message: "Cannot open the recording library lock: \(String(cString: strerror(errno)))") }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            Darwin.close(fd)
            throw RecordingFailure(message: "Unexpected recording library lock file.")
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd)
            throw RecordingFailure(message: "Another recording or transcription is still running in this library. Wait for it to finish, then retry.")
        }
    }

    func captureInput() throws -> FileHandle {
        let copy = dup(fd)
        guard copy >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return FileHandle(fileDescriptor: copy, closeOnDealloc: true)
    }

    // Closing the last duplicate releases flock. Explicit LOCK_UN here would
    // release it for still-running capture children after a failed app start.
    deinit { Darwin.close(fd) }
}

enum RecordingFiles {
    static func validate(_ rec: Recording, directory: URL) throws {
        guard !rec.id.isEmpty, rec.id != ".", rec.id != "..", !rec.id.contains("/"),
              rec.wav == rec.id + ".wav", rec.duration.isFinite, rec.duration >= 0 else {
            throw RecordingFailure(message: "This recording has invalid metadata and cannot be processed safely.")
        }
    }

    private static func validateTarget(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFREG else {
                throw RecordingFailure(message: "Unexpected file type for \(url.lastPathComponent).")
            }
        } else if errno != ENOENT {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    static func requireSpace(directory: URL, minimum: Int64 = 128 * 1024 * 1024) throws {
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: directory.path)
        guard let free = attributes[.systemFreeSize] as? NSNumber else {
            throw RecordingFailure(message: "Cannot check available recording space.")
        }
        guard free.int64Value >= minimum else {
            throw RecordingFailure(message: "Not enough free space to safely save a recording. Free some disk space, then retry.")
        }
    }

    static func load(_ id: String, directory: URL) throws -> Recording {
        let placeholder = Recording(id: id, title: "", startedAt: Date(), duration: 0, wav: id + ".wav")
        try validate(placeholder, directory: directory)
        try validateTarget(directory.appendingPathComponent(id + ".json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let rec = try decoder.decode(Recording.self, from: Data(contentsOf: directory.appendingPathComponent(id + ".json")))
        guard rec.id == id else { throw RecordingFailure(message: "Recording identity does not match its filename.") }
        try validate(rec, directory: directory)
        return rec
    }

    static func save(_ rec: Recording, directory: URL) throws {
        try validate(rec, directory: directory)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try write(encoder.encode(rec), to: directory.appendingPathComponent(rec.id + ".json"))
    }

    static func writeTranscript(_ rec: Recording, lines: [String], directory: URL,
                                partial: Bool = false) throws {
        try validate(rec, directory: directory)
        let name = rec.id + (partial ? ".partial.txt" : ".txt")
        try validateTarget(directory.appendingPathComponent(name))
        try write(Data(lines.joined(separator: "\n").utf8), to: directory.appendingPathComponent(name))
    }

    /// Persist the text first, then its completion state. If either write fails,
    /// callers report failure; an old transcript is never replaced by a failed
    /// decode. Empty successful output intentionally clears a stale preview.
    static func commit(_ rec: Recording, lines: [String], errors: [String], directory: URL,
                       speakers: SpeakerTranscript? = nil) throws -> Recording {
        var result = rec
        if errors.isEmpty {
            try speakers?.validate()
            try writeTranscript(rec, lines: lines, directory: directory)
            result.speakerTranscript = speakers
            result.speakerFailure = nil
            result.status = rec.captureIssue == nil ? .complete : .partial
            result.failure = rec.captureIssue
        } else {
            if !lines.isEmpty { try writeTranscript(rec, lines: lines, directory: directory, partial: true) }
            result.status = lines.isEmpty ? .failed : .partial
            result.failure = errors.joined(separator: "\n") + "\nThe previous transcript has been kept."
        }
        result.updatedAt = Date()
        try save(result, directory: directory)
        return result
    }

    private static func write(_ data: Data, to url: URL) throws {
        try validateTarget(url)
        let temporary = url.deletingLastPathComponent().appendingPathComponent("." + UUID().uuidString + ".pending")
        let fd = Darwin.open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        try handle.write(contentsOf: data)
        // Sync before replacement: a failed write/sync must leave the old
        // transcript at its original path, not replace it then report failure.
        try handle.synchronize()
        try handle.close()
        try validateTarget(url)
        guard Darwin.rename(temporary.path, url.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
}
