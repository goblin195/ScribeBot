// The calendar side of the library: who was in the room.
//
// bench/meetings.json is the same file meeting.py reads, and the matching rule
// here is a straight port of meeting.py's find(): a recording belongs to the
// invitation it started inside, and overlapping invitations break toward the
// one with the most named attendees so a real meeting beats a personal block.
import SwiftUI

struct CalMeeting: Identifiable, Hashable {
    let id: Int
    let title: String
    let start: Date
    let end: Date
    let location: String
    /// Organizer first, then attendees; addresses stripped, duplicates removed.
    let people: [String]
}

/// One row of the People pane.
struct Person: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let meetings: Int
    let recordings: Int
}

private struct RawMeeting: Decodable {
    let title: String?
    let start: String
    let end: String
    let location: String?
    let organizer: String?
    let attendees: [String]?
}

/// Port of meeting.py clean_name: "אדם חזן <a@b.co.il>" -> "אדם חזן",
/// a bare address -> nil (it names nobody).
func cleanName(_ raw: String) -> String? {
    let stripped = raw
        .replacingOccurrences(of: "\\s*<[^>]*>\\s*", with: "", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    guard !stripped.isEmpty else { return nil }
    let bareEmail = stripped.range(of: "^[^@\\s]+@[^@\\s]+$", options: .regularExpression) != nil
    return bareEmail ? nil : stripped
}

@MainActor
final class MeetingIndex: ObservableObject {
    static let shared = MeetingIndex()

    let meetings: [CalMeeting]
    /// meeting.py's SLACK: an invitation still owns a tape that starts a
    /// quarter of an hour early or runs a quarter of an hour long.
    private let slack: TimeInterval = 15 * 60

    init(url: URL = Paths.root.appendingPathComponent("bench/meetings.json")) {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode([RawMeeting].self, from: data) else {
            meetings = []
            return
        }
        meetings = raw.enumerated().compactMap { i, m in
            guard let s = iso.date(from: m.start), let e = iso.date(from: m.end) else { return nil }
            var seen = Set<String>()
            let people = ([m.organizer].compactMap { $0 } + (m.attendees ?? []))
                .compactMap(cleanName)
                .filter { seen.insert($0).inserted }
            return CalMeeting(id: i,
                              title: m.title?.trimmingCharacters(in: .whitespaces) ?? "Untitled",
                              start: s, end: e,
                              location: m.location?.trimmingCharacters(in: .whitespaces) ?? "",
                              people: people)
        }
    }

    /// The invitation a recording started during, or nil.
    func meeting(at date: Date) -> CalMeeting? {
        let hits = meetings.filter { $0.start - slack <= date && date <= $0.end + slack }
        return hits.max {
            if $0.people.count != $1.people.count { return $0.people.count < $1.people.count }
            return abs($0.start.timeIntervalSince(date)) > abs($1.start.timeIntervalSince(date))
        }
    }

    /// Everyone in the calendar, with how many of these recordings they sat in.
    func people(matching recordings: [Recording]) -> [Person] {
        var recCount: [String: Int] = [:]
        for r in recordings {
            for name in meeting(at: r.startedAt)?.people ?? [] {
                recCount[name, default: 0] += 1
            }
        }
        var meetCount: [String: Int] = [:]
        for m in meetings {
            for name in m.people { meetCount[name, default: 0] += 1 }
        }
        return meetCount
            .map { Person(name: $0.key, meetings: $0.value, recordings: recCount[$0.key] ?? 0) }
            .sorted {
                if $0.recordings != $1.recordings { return $0.recordings > $1.recordings }
                if $0.meetings != $1.meetings { return $0.meetings > $1.meetings }
                return $0.name.localizedCompare($1.name) == .orderedAscending
            }
    }

    /// Every invitation this person is named on, most recent first.
    func meetings(with name: String) -> [CalMeeting] {
        meetings.filter { $0.people.contains(name) }.sorted { $0.start > $1.start }
    }
}
