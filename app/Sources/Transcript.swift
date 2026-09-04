// The transcript as data: who said each line, where a search hits, and the
// segment list export.py wants. No SwiftUI here on purpose — this is the part
// worth checking without launching an app (see selftest/main.swift).
import Foundation

enum Speaker: String {
    case you = "You"
    case them = "Them"
    case unknown = ""

    var label: String { self == .unknown ? "" : rawValue.lowercased() }
}

struct TranscriptLine: Identifiable, Equatable {
    let id: Int
    let speaker: Speaker
    let text: String
}

/// One search hit: which line, and where inside it.
struct Match: Equatable {
    let line: Int
    let range: Range<String.Index>
}

enum Transcript {
    /// Lines carry an optional `You: ` / `Them: ` prefix. An unprefixed line
    /// continues whoever spoke last, because the live transcriber only labels
    /// the microphone stream. A file with no prefixes anywhere predates speaker
    /// attribution entirely, so it stays unattributed rather than being guessed.
    static func parse(_ raw: String) -> [TranscriptLine] {
        let rows = raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var current = Speaker.unknown
        var out: [TranscriptLine] = []
        for row in rows {
            var text = row
            for s in [Speaker.you, .them] where row.hasPrefix(s.rawValue + ":") {
                current = s
                text = String(row.dropFirst(s.rawValue.count + 1))
                    .trimmingCharacters(in: .whitespaces)
            }
            guard !text.isEmpty else { continue }
            out.append(TranscriptLine(id: out.count, speaker: current, text: text))
        }
        return out
    }

    static func isAttributed(_ lines: [TranscriptLine]) -> Bool {
        lines.contains { $0.speaker != .unknown }
    }

    /// What lands on the pasteboard: speaker prefixes kept only if they exist.
    static func plainText(_ lines: [TranscriptLine]) -> String {
        lines.map { l in
            l.speaker == .unknown ? l.text : "\(l.speaker.rawValue): \(l.text)"
        }.joined(separator: "\n")
    }

    /// Case- and diacritic-insensitive, so a Hebrew query with nikud still hits
    /// text without it and `SIEM` finds `siem`.
    static func search(_ lines: [TranscriptLine], _ query: String) -> [Match] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return [] }
        var hits: [Match] = []
        for line in lines {
            var from = line.text.startIndex
            while let r = line.text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive],
                                          range: from..<line.text.endIndex) {
                hits.append(Match(line: line.id, range: r))
                from = r.upperBound > r.lowerBound
                    ? r.upperBound : line.text.index(after: r.lowerBound)
                if from >= line.text.endIndex { break }
            }
        }
        return hits
    }

    /// export.py takes `[{start,end,text,speaker?}]`.
    ///
    /// Prefer REAL timestamps: `scribebot.py file <wav> --segments` re-decodes
    /// the audio and returns segment boundaries from the decoder. Fall back to
    /// the length-proportional split below only when the audio is unavailable -
    /// and that fallback is an estimate, which callers must disclose. It once
    /// produced a 19-minute subtitle for a 30-minute meeting, printed to the
    /// millisecond, with nothing in the interface saying it was invented.
    static func realSegments(wav: URL, scribebotPy: URL, root: URL) -> [[String: Any]]? {
        guard FileManager.default.fileExists(atPath: wav.path),
              FileManager.default.fileExists(atPath: scribebotPy.path) else { return nil }
        let p = Process()
        // Same reason as Recorder: a Finder-launched app resolves `env python3`
        // to Apple's 3.9, which cannot parse this project.
        p.executableURL = URL(fileURLWithPath: Paths.python)
        p.arguments = [scribebotPy.path, "file", wav.path, "--segments"]
        p.currentDirectoryURL = root
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            let d = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0,
                  let arr = try JSONSerialization.jsonObject(with: d) as? [[String: Any]],
                  !arr.isEmpty else { return nil }
            return arr
        } catch { return nil }
    }

    /// Length-proportional fallback. An ESTIMATE, not a measurement.
    static func segmentsJSON(_ lines: [TranscriptLine], duration: TimeInterval) throws -> Data {
        let total = max(lines.reduce(0) { $0 + $1.text.count }, 1)
        let span = duration > 0 ? duration : Double(total) / 15  // ~15 chars/sec fallback
        var t = 0.0
        var segs: [[String: Any]] = []
        for line in lines {
            let dt = span * Double(line.text.count) / Double(total)
            var seg: [String: Any] = ["start": t, "end": t + dt, "text": line.text]
            if line.speaker != .unknown { seg["speaker"] = line.speaker.rawValue }
            segs.append(seg)
            t += dt
        }
        return try JSONSerialization.data(withJSONObject: segs,
                                          options: [.prettyPrinted, .withoutEscapingSlashes])
    }
}

/// The three sections summarize.py promises, kept apart so they can be styled
/// apart. Anything before the first heading is treated as the abstract.
struct Summary {
    var abstract: String = ""
    var decisions: [String] = []
    var tasks: [String] = []

    static let headings = ["## תקציר", "## החלטות", "## משימות"]

    init(markdown: String) {
        var section = 0
        var abstractLines: [String] = []
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                if line.contains("תקציר") { section = 0 }
                else if line.contains("החלטות") { section = 1 }
                else if line.contains("משימות") { section = 2 }
                continue
            }
            guard !line.isEmpty else { continue }
            let body = Summary.unbullet(line)
            switch section {
            case 1: decisions.append(body)
            case 2: tasks.append(body)
            default: abstractLines.append(line)
            }
        }
        abstract = abstractLines.joined(separator: " ")
    }

    var isEmpty: Bool { abstract.isEmpty && decisions.isEmpty && tasks.isEmpty }

    /// Strip a leading list marker only — "- foo", "* foo", "1. foo", "2) foo".
    /// Deliberately conservative: a task that genuinely starts with a year
    /// must not lose it.
    static func unbullet(_ line: String) -> String {
        var s = Substring(line)
        if let f = s.first, "-*•–".contains(f) {
            s = s.dropFirst()
        } else {
            let digits = s.prefix { $0.isNumber }
            if !digits.isEmpty, digits.count <= 2,
               let sep = s.dropFirst(digits.count).first, ".)".contains(sep),
               s.dropFirst(digits.count + 1).first == " " {
                s = s.dropFirst(digits.count + 1)
            }
        }
        // Models emit **bold** run-ins ("**Danny:** ..."); we style headings
        // ourselves, so the markers are noise rather than emphasis.
        return s.replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: .whitespaces)
    }
}
