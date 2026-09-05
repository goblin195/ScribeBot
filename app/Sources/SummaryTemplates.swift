// The summary templates the Summary menu offers.
//
// templates.json is read by this app AND by summarize.py. One file on purpose:
// the section list used to be written out twice, and the app parsed its own
// summaries by searching for three specific Hebrew headings, so any template
// with different sections produced output the app could not read back.
//
// Templates the user makes are appended to templates.user.json in Application
// Support, beside the recordings, and layered over the built-ins by id.
import SwiftUI

struct SummaryTemplate: Identifiable, Codable, Hashable {
    struct Section: Codable, Hashable {
        var en: String
        var he: String
        var guidance: String = ""
    }
    var id: String
    var name: String
    var description: String = ""
    var sections: [Section]
    /// Not persisted - derived from which file the template came out of.
    var userDefined: Bool = false

    private enum CodingKeys: String, CodingKey { case id, name, description, sections }

    var sectionSummary: String { sections.map(\.en).joined(separator: " · ") }
}

private struct TemplateFile: Codable { var templates: [SummaryTemplate] }

@MainActor
final class SummaryTemplates: ObservableObject {
    static let shared = SummaryTemplates()

    @Published private(set) var all: [SummaryTemplate] = []
    /// Free text from "Change how it's written…", passed to summarize.py.
    @Published private(set) var instructions: String = UserDefaults.standard
        .string(forKey: "summaryInstructions") ?? ""

    static let defaultID = "standard"

    private init() { reload() }

    // MARK: - Files

    static var builtinURL: URL { Paths.root.appendingPathComponent("templates.json") }
    static var userURL: URL { Paths.support.appendingPathComponent("templates.user.json") }

    func reload() {
        var ordered = decode(Self.builtinURL, userDefined: false)
        for t in decode(Self.userURL, userDefined: true) {
            if let i = ordered.firstIndex(where: { $0.id == t.id }) { ordered[i] = t }
            else { ordered.append(t) }
        }
        // A missing or unreadable templates.json must not leave the menu empty
        // and the Summary button dead - fall back to what summarize.py itself
        // defaults to.
        all = ordered.isEmpty ? [Self.fallback] : ordered
    }

    private func decode(_ url: URL, userDefined: Bool) -> [SummaryTemplate] {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(TemplateFile.self, from: data)
        else { return [] }
        return file.templates.map { var t = $0; t.userDefined = userDefined; return t }
    }

    static let fallback = SummaryTemplate(
        id: defaultID, name: "Standard",
        description: "What the meeting was about, what was decided, who owes what.",
        sections: [.init(en: "Summary", he: "תקציר", guidance: "2-4 sentences"),
                   .init(en: "Decisions", he: "החלטות", guidance: "decisions reached"),
                   .init(en: "Tasks", he: "משימות", guidance: "tasks and owners")])

    func template(_ id: String) -> SummaryTemplate {
        all.first { $0.id == id } ?? all.first ?? Self.fallback
    }

    // MARK: - Selection, remembered per recording

    private static func key(_ recording: String) -> String { "summaryTemplate.\(recording)" }

    static func selectedID(for recording: String) -> String {
        UserDefaults.standard.string(forKey: key(recording))
            ?? UserDefaults.standard.string(forKey: "summaryTemplate")
            ?? defaultID
    }

    static func select(_ id: String, for recording: String) {
        UserDefaults.standard.set(id, forKey: key(recording))
        // Also the default for the next recording: choosing Standup once
        // usually means the next standup as well.
        UserDefaults.standard.set(id, forKey: "summaryTemplate")
    }

    func setInstructions(_ text: String) {
        instructions = text
        UserDefaults.standard.set(text, forKey: "summaryInstructions")
    }

    // MARK: - User templates

    /// nil on success, or a message to put in front of the user.
    func save(_ template: SummaryTemplate) -> String? {
        guard !template.name.trimmingCharacters(in: .whitespaces).isEmpty else {
            return "A template needs a name."
        }
        guard !template.sections.isEmpty else {
            return "A template needs at least one section."
        }
        var existing = decode(Self.userURL, userDefined: true)
        if let i = existing.firstIndex(where: { $0.id == template.id }) { existing[i] = template }
        else { existing.append(template) }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        do {
            try enc.encode(TemplateFile(templates: existing))
                .write(to: Self.userURL, options: .atomic)
        } catch {
            return "Could not save the template: \(error.localizedDescription)"
        }
        reload()
        return nil
    }

    /// A slug that collides with neither a built-in nor another user template.
    func freeID(from name: String) -> String {
        let cleaned = name.lowercased()
            .map { ($0.isLetter || $0.isNumber) ? $0 : "-" }
            .reduce(into: "") { $0.append($1) }
        let stem = cleaned.split(separator: "-").joined(separator: "-")
        var candidate = stem.isEmpty ? "template" : stem
        var n = 2
        while all.contains(where: { $0.id == candidate }) {
            candidate = "\(stem.isEmpty ? "template" : stem)-\(n)"; n += 1
        }
        return candidate
    }
}
