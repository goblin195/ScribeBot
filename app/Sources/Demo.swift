// ponytail: test hook, not a feature. SCRIBEBOT_DEMO=1 hangs a handful of
// in-memory recordings off the real calendar so the main window can be
// screenshotted — day grouping, attendee lists, mixed-direction text and the
// them/you pairing — without waiting for nine real meetings to happen.
// Nothing here is ever written to disk.
import SwiftUI

private let demoLines: [[String]] = [
    ["Them: אוקיי, אז בואו נסכם את מה שדיברנו עליו בסשן הקודם.",
     "You: צריך לעשות deploy לפרודקשן עד יום חמישי.",
     "Them: The SIEM integration is blocked on the CrowdStrike API key.",
     "You: אמרתי לאורנה שה-SLA שלנו הוא ארבע שעות, לא עשרים וארבע.",
     "Them: ואז נצטרך לבדוק את ה-latency של ה-gateway מול טורונטו."],
    ["Them: מבחינת ה-migration, יש לנו עוד שלוש מאות משתמשים בתור.",
     "You: I'll take the ZTNA policy review, send me the Symantec export.",
     "Them: הבעיה היא שה-tenant הישן עדיין מחזיק את ה-DNS.",
     "You: נסגור את זה בחלון השינויים של יום ראשון בלילה."],
    ["Them: The POC environment is up, but throughput drops under 40 Mbps.",
     "You: זה ה-proxy. תוריד את ה-inspection ותמדוד שוב.",
     "Them: מסכים. אני מעדכן את המסמך ושולח לכולם עד סוף היום."],
    ["Them: צריך לעשות deploy לפרודקשן עד יום חמישי, אחרת מפספסים את החלון.",
     "Them: אני אכתוב את זה ב-runbook."],
    ["You: בוא נעבור על ה-findings של הסריקה האחרונה.",
     "You: שלושה critical, כולם באותו container image."],
]

extension Library {
    /// Seed from the real calendar so titles, times and attendees are genuine.
    func seedDemo(_ index: MeetingIndex) {
        let now = Date()
        let picks = index.meetings
            .filter { $0.start < now && $0.people.count >= 2 }
            .sorted { $0.start > $1.start }
            .prefix(9)
        var seeded: [Recording] = []
        var text: [String: String] = [:]
        var sides: [String: Sides] = [:]
        for (n, m) in picks.enumerated() {
            let id = "demo-\(m.id)"
            let lines = demoLines[n % demoLines.count]
            // Every third tape lost a side — the mixed case has to be visible.
            let solo = n % 3 == 2
            text[id] = (solo ? lines.filter { $0.hasPrefix("Them:") } : lines)
                .joined(separator: "\n")
            sides[id] = solo ? .themOnly : .both
            seeded.append(Recording(id: id, title: m.title,
                                    startedAt: m.start.addingTimeInterval(92),
                                    duration: min(m.end.timeIntervalSince(m.start) - 300, 3_140),
                                    wav: "\(id).wav"))
        }
        inject(seeded, sides: sides, transcripts: text)
    }
}
