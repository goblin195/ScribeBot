// Offline check for the transcript model. Not part of the app bundle —
// build.sh only globs Sources/*.swift.
//
//   swiftc -O app/Sources/Transcript.swift app/selftest/main.swift -o /tmp/tcheck && /tmp/tcheck
import Foundation

func check(_ ok: Bool, _ what: String) {
    if !ok { print("FAIL: \(what)"); exit(1) }
}

// speaker prefixes, and an unprefixed line continuing the last speaker
let lines = Transcript.parse("""
Them: אוקיי, אז בואו נסכם.
צריך לעשות deploy לפרודקשן עד יום חמישי.
You: אמרתי לאורנה שה-SLA שלנו הוא ארבע שעות.

""")
check(lines.count == 3, "blank lines dropped")
check(lines[0].speaker == .them && lines[1].speaker == .them, "unprefixed line inherits")
check(lines[2].speaker == .you, "You: parsed")
check(lines[0].text.hasPrefix("אוקיי"), "prefix stripped: \(lines[0].text)")
check(Transcript.isAttributed(lines), "attributed")

// a legacy file with no prefixes stays unattributed rather than guessing
let legacy = Transcript.parse("שורה אחת\nשורה שתיים")
check(!Transcript.isAttributed(legacy), "legacy transcript not guessed")
check(Transcript.plainText(legacy) == "שורה אחת\nשורה שתיים", "plain round-trip")
check(Transcript.plainText(lines).hasPrefix("Them: אוקיי"), "copy keeps speakers")

// search: case-insensitive, every occurrence, no infinite loop on repeats
let hits = Transcript.search(lines, "deploy")
check(hits.count == 1 && hits[0].line == 1, "found deploy")
check(Transcript.search(lines, "DEPLOY").count == 1, "case-insensitive")
check(Transcript.search(lines, "א").isEmpty, "single char ignored")
let repeated = Transcript.parse("aa aa aa")
check(Transcript.search(repeated, "aa").count == 3, "all occurrences")

// segments: monotonic, cover the duration, speaker only when known
let data = try! Transcript.segmentsJSON(lines, duration: 60)
let segs = try! JSONSerialization.jsonObject(with: data) as! [[String: Any]]
check(segs.count == 3, "one segment per line")
check(abs((segs[2]["end"] as! Double) - 60) < 0.001, "ends at duration")
check((segs[0]["start"] as! Double) == 0, "starts at zero")
for i in 1..<segs.count {
    check((segs[i]["start"] as! Double) >= (segs[i - 1]["end"] as! Double) - 0.001, "monotonic")
}
check(segs[2]["speaker"] as? String == "You", "speaker carried")
let noSpeaker = try! JSONSerialization.jsonObject(
    with: try! Transcript.segmentsJSON(legacy, duration: 0)) as! [[String: Any]]
check(noSpeaker[0]["speaker"] == nil, "unattributed segments omit speaker")
check((noSpeaker[1]["end"] as! Double) > 0, "zero duration still produces a timeline")

// summary sections
let s = Summary(markdown: """
## תקציר
הפגישה עסקה בפריסת ה-SIEM.

## החלטות
- לדחות את ה-deploy ליום חמישי
2. להשאיר את ה-SLA על ארבע שעות

## משימות
- אורנה: לבדוק את ה-latency
""")
check(s.abstract.contains("SIEM"), "abstract: \(s.abstract)")
check(s.decisions.count == 2, "decisions: \(s.decisions)")
check(s.decisions[0] == "לדחות את ה-deploy ליום חמישי", "bullet stripped: \(s.decisions[0])")
check(s.decisions[1] == "להשאיר את ה-SLA על ארבע שעות", "enumeration stripped")
check(s.tasks.count == 1 && s.tasks[0].contains("אורנה"), "tasks")
check(Summary.unbullet("2026 היה קשה") == "2026 היה קשה", "year is not a bullet")
check(Summary(markdown: "").isEmpty, "empty summary")

// what the Copy button puts on the pasteboard: every section, in order
let md = s.markdown
check(md.hasPrefix("## תקציר"), "markdown opens on the first heading: \(md.prefix(24))")
check(md.contains("\n## החלטות\n"), "later headings kept")
check(md.contains("- לדחות את ה-deploy ליום חמישי"), "list items are bulleted")
check(md.contains("- אורנה"), "the last section is copied too, not just the visible one")
check(Summary(markdown: md).sections.count == s.sections.count, "markdown round-trips")
check(Summary(markdown: "פתיח לפני הכותרת\n\n## תקציר\nכן.").markdown
        .hasPrefix("פתיח לפני הכותרת\n\n## תקציר"), "preamble is copied before the headings")

// which way the summary reads. Per-line rules are wrong here: the second one
// opens with an English term and is still a Hebrew summary.
check(s.isHebrew, "Hebrew summary reads RTL")
check(Summary(markdown: "## תקציר\nSIEM-ה נפרס ביום חמישי.").isHebrew,
      "Hebrew carrying English terms still reads RTL")
check(!Summary(markdown: "## Summary\nWe agreed to ship on Thursday.").isHebrew,
      "an English summary stays LTR")
check(!Summary(markdown: "## Summary\nThe deploy is on Thursday. Owner: אורנה")
        .isHebrew, "English carrying a Hebrew name stays LTR")

print("transcript self-check passed")
