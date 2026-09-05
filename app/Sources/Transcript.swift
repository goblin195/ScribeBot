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
        p.arguments = ["-B", scribebotPy.path, "file", wav.path, "--segments"]
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

/// A summary as summarize.py writes it: `## heading` sections in the order the
/// chosen template asked for them, kept apart so they can be styled apart.
struct Summary {
    /// One `## heading` and the lines under it. Sections are whatever the
    /// chosen template asked for, in the order it asked for them - this used
    /// to be three fixed Hebrew headings, so a template with any other section
    /// produced a summary the app could not read back.
    struct Section: Identifiable {
        let id: Int
        let title: String
        let items: [String]
        /// A single long run reads as a paragraph; anything else is a list.
        var isProse: Bool { items.count == 1 && items[0].count > 60 }
    }

    /// Anything before the first heading. Usually nothing: the models put
    /// everything under a heading.
    var preamble: String = ""
    var sections: [Section] = []

    /// The opening prose. Callers that predate templates - the live view's
    /// summary band - expect the first section to be the abstract, which is
    /// exactly what the standard template's "תקציר" is, so keep answering that.
    var abstract: String {
        preamble.isEmpty
            ? (sections.first.map { $0.items.joined(separator: " ") } ?? "")
            : preamble
    }

    init(markdown: String) {
        var abstractLines: [String] = []
        var titles: [String] = []
        var bodies: [[String]] = []
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                let title = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                titles.append(Summary.unbullet(title))
                bodies.append([])
                continue
            }
            guard !line.isEmpty else { continue }
            if bodies.isEmpty { abstractLines.append(line) }
            else { bodies[bodies.count - 1].append(Summary.unbullet(line)) }
        }
        preamble = abstractLines.joined(separator: " ")
        sections = zip(titles, bodies).enumerated().compactMap { i, pair in
            pair.1.isEmpty ? nil : Section(id: i, title: pair.0, items: pair.1)
        }
    }

    /// The whole summary as Markdown, in section order. Rebuilt from the
    /// parsed sections rather than kept as the model's raw output, so what the
    /// copy button puts on the pasteboard is exactly what the view renders -
    /// bullets already normalised, `**bold**` run-ins already gone.
    var markdown: String {
        var blocks: [String] = []
        if !preamble.isEmpty { blocks.append(preamble) }
        for s in sections {
            blocks.append("## \(s.title)")
            blocks.append(s.isProse
                ? s.items[0]
                : s.items.map { "- \($0)" }.joined(separator: "\n"))
        }
        return blocks.joined(separator: "\n\n")
    }

    /// Which script the summary is written in, by letter count. This is a
    /// different question from `baseDirection` in RTL.swift, which reads the
    /// first strong character of ONE line: a Hebrew section that happens to
    /// open with an English product name is still a Hebrew section, and
    /// deciding per line put its heading and bullets on the wrong edge.
    static func isHebrew(_ text: String) -> Bool {
        var hebrew = 0, latin = 0
        for u in text.unicodeScalars {
            switch u.value {
            case 0x0590...0x05FF: hebrew += 1
            case 0x0041...0x005A, 0x0061...0x007A: latin += 1
            default: continue
            }
        }
        return hebrew > latin
    }

    var isHebrew: Bool { Summary.isHebrew(markdown) }

    /// Lookups the standard template's sections still answer to, so a caller
    /// that only wants decisions does not have to know about templates.
    private func section(_ needles: [String]) -> [String] {
        sections.first { s in
            let t = s.title.lowercased()
            return needles.contains { t.contains($0) }
        }?.items ?? []
    }
    var decisions: [String] { section(["החלטות", "decision"]) }
    var tasks: [String] { section(["משימות", "task", "action item"]) }

    var isEmpty: Bool { preamble.isEmpty && sections.isEmpty }

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
