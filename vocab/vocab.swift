// scribebot vocabulary sourcing.
// Glossary restoration only repairs terms it already knows, so the glossary has
// to be built from the user's own world: who they meet, and what those meetings
// are called. Calendar titles carry vendor and project names; attendees carry
// the proper nouns that every transcriber mangles.
import Foundation
import EventKit
import Contacts

func log(_ m: String) { FileHandle.standardError.write("→ \(m)\n".data(using: .utf8)!) }

/// Latin-script tokens worth keeping, plus Hebrew-free proper nouns.
let TOKEN = try! NSRegularExpression(pattern: "[A-Za-z][A-Za-z0-9+._-]{1,}")
let STOP: Set<String> = [
    "the","and","for","with","from","this","that","you","your","our","are","was",
    "will","have","has","not","but","all","can","its","meet","meeting","call",
    "sync","weekly","daily","monthly","invite","zoom","http","https","www","com",
    "org","net","re","fw","am","pm","min","hr","hrs","new","old","re-","tbd",
]

func extract(_ s: String) -> [String] {
    let ns = s as NSString
    var out: [String] = []
    for m in TOKEN.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
        let t = ns.substring(with: m.range)
        let low = t.lowercased()
        if low.count < 2 || STOP.contains(low) { continue }
        if low.allSatisfy(\.isNumber) { continue }
        out.append(t)
    }
    return out
}

func calendarTerms(daysBack: Int, daysForward: Int) -> [String: Int] {
    let store = EKEventStore()
    var granted = false
    let sem = DispatchSemaphore(value: 0)
    store.requestFullAccessToEvents { ok, err in
        granted = ok
        if let err { log("calendar error: \(err.localizedDescription)") }
        sem.signal()
    }
    _ = sem.wait(timeout: .now() + 60)
    guard granted else { log("calendar access denied"); return [:] }

    let cal = Calendar.current
    let start = cal.date(byAdding: .day, value: -daysBack, to: Date())!
    let end   = cal.date(byAdding: .day, value: daysForward, to: Date())!
    let pred  = store.predicateForEvents(withStart: start, end: end, calendars: nil)
    let events = store.events(matching: pred)
    log("scanned \(events.count) calendar events")

    // Deliberately NOT reading e.notes. The notes body of a Teams/Zoom invite is
    // join URLs, tenant GUIDs and "do not open links unless you know the sender"
    // banners - none of it is ever spoken, and all of it poisons the glossary.
    // Titles and attendee names are what people actually say in the meeting.
    var counts: [String: Int] = [:]
    for e in events {
        var text = [e.title ?? ""]
        if let loc = e.location, !loc.contains("http") { text.append(loc) }
        for a in e.attendees ?? [] { if let n = a.name { text.append(n) } }
        for t in extract(text.joined(separator: " ")) {
            counts[t, default: 0] += 1
        }
    }
    return counts
}

func contactTerms() -> [String: Int] {
    let store = CNContactStore()
    var granted = false
    let sem = DispatchSemaphore(value: 0)
    store.requestAccess(for: .contacts) { ok, _ in granted = ok; sem.signal() }
    _ = sem.wait(timeout: .now() + 60)
    guard granted else { log("contacts access denied"); return [:] }

    let keys = [CNContactGivenNameKey, CNContactFamilyNameKey,
                CNContactOrganizationNameKey] as [CNKeyDescriptor]
    var counts: [String: Int] = [:]
    var n = 0
    let req = CNContactFetchRequest(keysToFetch: keys)
    try? store.enumerateContacts(with: req) { c, _ in
        n += 1
        for t in extract("\(c.givenName) \(c.familyName) \(c.organizationName)") {
            counts[t, default: 0] += 1
        }
    }
    log("scanned \(n) contacts")
    return counts
}

struct Meeting: Encodable {
    let title: String
    let start: String
    let end: String
    let attendees: [String]
    let organizer: String?
    let location: String?
}

func meetings(daysBack: Int, daysForward: Int) -> [Meeting] {
    let store = EKEventStore()
    var granted = false
    let sem = DispatchSemaphore(value: 0)
    store.requestFullAccessToEvents { ok, _ in granted = ok; sem.signal() }
    _ = sem.wait(timeout: .now() + 60)
    guard granted else { return [] }
    let cal = Calendar.current
    let start = cal.date(byAdding: .day, value: -daysBack, to: Date())!
    let end = cal.date(byAdding: .day, value: daysForward, to: Date())!
    let iso = ISO8601DateFormatter()
    return store.events(matching:
        store.predicateForEvents(withStart: start, end: end, calendars: nil))
        .filter { !($0.title ?? "").isEmpty && !$0.isAllDay }
        .map { e in
            Meeting(title: e.title ?? "",
                    start: iso.string(from: e.startDate),
                    end: iso.string(from: e.endDate),
                    attendees: (e.attendees ?? []).compactMap { $0.name },
                    organizer: e.organizer?.name,
                    location: (e.location?.contains("http") ?? true) ? nil : e.location)
        }
}

// MARK: - main

let args = CommandLine.arguments
let outPath = args.count > 1 ? args[1] : "vocab.json"
var merged: [String: Int] = [:]
for (k, v) in calendarTerms(daysBack: 180, daysForward: 30) { merged[k, default: 0] += v }
for (k, v) in contactTerms() { merged[k, default: 0] += v }

// Collapse case variants onto the most frequently seen spelling.
var byLower: [String: (term: String, n: Int)] = [:]
for (t, n) in merged {
    let k = t.lowercased()
    if let cur = byLower[k] { if n > cur.n { byLower[k] = (t, n + cur.n) } else { byLower[k] = (cur.term, n + cur.n) } }
    else { byLower[k] = (t, n) }
}
let terms = byLower.values.sorted { $0.n != $1.n ? $0.n > $1.n : $0.term < $1.term }
let payload: [String: Any] = [
    "generated": ISO8601DateFormatter().string(from: Date()),
    "terms": terms.map { ["term": $0.term, "count": $0.n] },
]
// meetings.json sits beside the vocabulary - same scan, different use
let meetingsPath = URL(fileURLWithPath: outPath)
    .deletingLastPathComponent().appendingPathComponent("meetings.json")
let mtgs = meetings(daysBack: 180, daysForward: 30)
let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
try enc.encode(mtgs).write(to: meetingsPath)
log("wrote \(mtgs.count) meetings → \(meetingsPath.lastPathComponent)")

let data = try JSONSerialization.data(withJSONObject: payload,
                                      options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
try data.write(to: URL(fileURLWithPath: outPath))
log("wrote \(terms.count) terms → \(outPath)")
for t in terms.prefix(25) { print(String(format: "%4d  %@", t.n, t.term)) }
