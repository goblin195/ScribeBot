// Where recordings live, and what we know about them.
// Everything is a plain file under Application Support — no database, no
// service, nothing that leaves the machine.
import SwiftUI
import EventKit

struct Recording: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var startedAt: Date
    var duration: TimeInterval
    var wav: String          // filename, resolved against Paths.recordings

    var durationText: String {
        let s = Int(duration.rounded())
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}

enum Paths {
    /// The checkout that owns the capture helper and the python pipeline.
    /// Walk up from the bundle so the app works from app/ or anywhere else.
    static let root: URL = {
        if let resources = Bundle.main.resourceURL {
            let bundled = resources.appendingPathComponent("Runtime")
            if FileManager.default.fileExists(atPath: bundled.appendingPathComponent("live.py").path) {
                return bundled
            }
        }
        var dir = Bundle.main.bundleURL
        for _ in 0..<6 {
            dir.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("live.py").path) {
                return dir
            }
        }
        return Bundle.main.bundleURL.deletingLastPathComponent()
    }()

    static let captureHelper = root
        .appendingPathComponent("capture/ScribebotCapture.app/Contents/MacOS/ScribebotCapture")
    static let livePy = root.appendingPathComponent("live.py")
    static let scribebotPy = root.appendingPathComponent("scribebot.py")

    /// A Python that can actually run this project.
    ///
    /// Launched from Finder an app does not inherit the shell PATH, so
    /// `/usr/bin/env python3` finds Apple's 3.9.6 - and the code uses `X | None`
    /// syntax that needs 3.10. Every finalize crashed on a SyntaxError, silently,
    /// leaving the live preview as the saved transcript: recordings appeared to
    /// "stop transcribing in the middle". Terminal runs were fine, which is
    /// exactly why it survived so long.
    static let python: String = {
        let candidates = [root.appendingPathComponent("python/bin/python3").path, "/opt/homebrew/bin/python3", "/usr/local/bin/python3",
                          "/usr/bin/python3"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = ["-B", "-c", "import sys; sys.exit(0 if sys.version_info >= (3,10) else 1)"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            if (try? p.run()) != nil {
                p.waitUntilExit()
                if p.terminationStatus == 0 { return path }
            }
        }
        return "/usr/bin/python3"   // will fail loudly rather than silently
    }()

    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Scribebot")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()
    static let recordings: URL = {
        let d = support.appendingPathComponent("recordings")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
}

/// Which halves of the conversation survived. `<id>.wav` is the far side,
/// `<id>-you.wav` the local microphone; either can be missing when a permission
/// was refused or a device vanished mid-call.
enum Sides {
    case both, themOnly, youOnly, missing

    var label: String {
        switch self {
        case .both: return "them+you"
        case .themOnly: return "them only"
        case .youOnly: return "you only"
        case .missing: return "no audio"
        }
    }
    var them: Bool { self == .both || self == .themOnly }
    var you: Bool { self == .both || self == .youOnly }
}

/// A recording that satisfied a search, plus the line that made it match.
struct Hit: Identifiable {
    var id: String { rec.id }
    let rec: Recording
    /// nil when the title matched; otherwise the fragment of transcript that did.
    let snippet: String?
    /// Range of the search match inside `snippet`, for highlighting.
    var match: Range<String.Index>? = nil
}

@MainActor
final class Library: ObservableObject {
    @Published private(set) var items: [Recording] = []
    @Published private(set) var sides: [String: Sides] = [:]

    /// Transcripts are small and read constantly (search touches all of them),
    /// so they are held after the first read and dropped on reload.
    /// Transcript text keyed by id, with the file's modification date at the
    /// time it was read. Without the date a transcript rewritten on disk - by
    /// the background finalize pass, or by `scribebot.py rebuild` - stayed
    /// invisible until the app was relaunched, so the accurate text existed on
    /// disk while the interface still showed the stale one.
    private var cache: [String: (text: String, stamp: Date)] = [:]
    /// ponytail: demo fixtures live in memory only, never on disk. See Demo.swift.
    var demoTranscripts: [String: String] = [:]

    init() { reload() }

    func reload() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: Paths.recordings,
                                                 includingPropertiesForKeys: nil)) ?? []
        let names = Set(files.map(\.lastPathComponent))
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        cache = [:]
        let found = files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? dec.decode(Recording.self, from: Data(contentsOf: $0)) }
        items = (found + items.filter { demoTranscripts[$0.id] != nil })
            .sorted { $0.startedAt > $1.startedAt }
        for r in found {
            let them = names.contains(r.wav)
            let you = names.contains(r.wav.replacingOccurrences(of: ".wav", with: "-you.wav"))
            sides[r.id] = them && you ? .both : them ? .themOnly : you ? .youOnly : .missing
        }
    }

    /// ponytail: demo fixture injection only — see Demo.swift. Nothing written.
    func inject(_ recs: [Recording], sides s: [String: Sides], transcripts t: [String: String]) {
        demoTranscripts.merge(t) { _, new in new }
        sides.merge(s) { _, new in new }
        items = (items + recs).sorted { $0.startedAt > $1.startedAt }
    }

    // MARK: - Search

    /// Title and transcript, both. A query that only appears in the spoken text
    /// still finds the tape, and reports the fragment it found it in.
    func hits(_ query: String) -> [Hit] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return items.map { Hit(rec: $0, snippet: nil) } }
        return items.compactMap { r in
            if r.title.localizedCaseInsensitiveContains(q) { return Hit(rec: r, snippet: nil) }
            guard let s = Library.snippet(transcript(r), around: q) else { return nil }
            return Hit(rec: r, snippet: s.text, match: s.match)
        }
    }

    /// ~36 characters of context either side of the match, elided at both ends.
    /// The single transcript line containing the match, trimmed at word
    /// boundaries, with the matched range returned so the view can highlight it.
    ///
    /// This used to take a fixed 36-character window either side of the hit and
    /// join the lines it spanned with " · ". That spliced together text of
    /// opposite direction — a Hebrew line and an English one — and cut both
    /// mid-word, producing something genuinely unreadable in the one place that
    /// matters most for re-finding a meeting. One line, whole words, and the
    /// match marked.
    static func snippet(_ text: String, around q: String) -> (text: String, match: Range<String.Index>)? {
        guard let hit = text.range(of: q, options: .caseInsensitive) else { return nil }
        // the line the match falls on - never splice across a newline
        let lineStart = text[..<hit.lowerBound].lastIndex(of: "\n")
            .map { text.index(after: $0) } ?? text.startIndex
        let lineEnd = text[hit.upperBound...].firstIndex(of: "\n") ?? text.endIndex
        var lo = lineStart, hi = lineEnd

        // trim to whole words when the line is long, keeping the match inside
        let budget = 40
        if let back = text.index(hit.lowerBound, offsetBy: -budget, limitedBy: lineStart) {
            lo = text[lineStart..<back].isEmpty ? lineStart
               : (text[back..<hit.lowerBound].firstIndex(of: " ").map { text.index(after: $0) } ?? back)
        }
        if let fwd = text.index(hit.upperBound, offsetBy: budget, limitedBy: lineEnd) {
            hi = text[hit.upperBound..<fwd].isEmpty ? lineEnd
               : (text[fwd..<lineEnd].firstIndex(of: " ") ?? fwd)
        }
        let head = lo == lineStart ? "" : "…"
        let tail = hi == lineEnd ? "" : "…"
        let body = String(text[lo..<hi])
        let full = head + body + tail
        // re-locate the match inside the assembled snippet
        guard let m = full.range(of: q, options: .caseInsensitive) else { return nil }
        return (full, m)
    }

    /// Write a transcript to disk without needing the main actor, so a decode
    /// that finishes as the app is quitting is not lost.
    static func writeTranscript(_ r: Recording, lines: [String]) {
        try? lines.joined(separator: "\n")
            .write(to: Paths.recordings.appendingPathComponent("\(r.id).txt"),
                   atomically: true, encoding: .utf8)
    }

    func save(_ r: Recording, transcript: [String]) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = .prettyPrinted
        try? enc.encode(r).write(to: Paths.recordings.appendingPathComponent("\(r.id).json"))
        if !transcript.isEmpty {
            try? transcript.joined(separator: "\n")
                .write(to: Paths.recordings.appendingPathComponent("\(r.id).txt"),
                       atomically: true, encoding: .utf8)
        }
        reload()
    }

    func transcript(_ r: Recording) -> String {
        if let d = demoTranscripts[r.id] { return d }
        let url = Paths.recordings.appendingPathComponent("\(r.id).txt")
        let stamp = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]
                     as? Date) ?? nil
        if let c = cache[r.id], c.stamp == stamp { return c.text }
        let t = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        cache[r.id] = (t, stamp ?? .distantPast)
        return t
    }

    func delete(_ r: Recording, selection: RecordingDeletion) throws {
        guard demoTranscripts[r.id] == nil else {
            throw NSError(domain: "Scribebot", code: 3, userInfo: [NSLocalizedDescriptionKey: "Demo calls cannot be deleted."])
        }
        defer { reload() }
        try selection.perform(id: r.id, wav: r.wav, directory: Paths.recordings) { url in
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    }

    func reveal(_ r: Recording) {
        NSWorkspace.shared.activateFileViewerSelecting(
            [Paths.recordings.appendingPathComponent(r.wav)])
    }
}

/// Name the tape after the meeting it happened in. Same tie-break as meeting.py:
/// overlapping invitations lose to the one with the most named attendees, so a
/// real meeting beats a personal calendar block.
func calendarTitle(at date: Date, store: EKEventStore) -> String? {
    guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return nil }
    let slack: TimeInterval = 15 * 60
    let pred = store.predicateForEvents(withStart: date.addingTimeInterval(-slack),
                                        end: date.addingTimeInterval(slack),
                                        calendars: nil)
    let hits = store.events(matching: pred).filter { !$0.isAllDay }
    guard !hits.isEmpty else { return nil }
    let best = hits.max { a, b in
        let ca = a.attendees?.count ?? 0, cb = b.attendees?.count ?? 0
        if ca != cb { return ca < cb }
        return abs(a.startDate.timeIntervalSince(date)) > abs(b.startDate.timeIntervalSince(date))
    }
    return best?.title
}
