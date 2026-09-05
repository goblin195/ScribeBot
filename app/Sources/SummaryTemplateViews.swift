// The Transcription / Summary pill, and the three sheets its menu opens.
//
// Kept out of RecordingDetail.swift so that file stays about one recording
// rather than about template management.
import SwiftUI

/// One half of the segmented pill. The fill is the only thing marking the
/// active half, so it has to read in both themes.
struct Segment: ButtonStyle {
    var active: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(T.body(12.5, .semibold))
            .labelStyle(.titleAndIcon)
            .imageScale(.small)
            .foregroundStyle(active ? P.surface : P.ink2)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(active ? P.ink : .clear, in: Capsule())
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// One `## heading` of a summary. A single long run is a paragraph, anything
/// else is a list: a template's sections are not all the same shape - "Summary"
/// is prose and "Blockers" is a list.
struct SummarySection: View {
    let section: Summary.Section

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(section.title)
                .font(T.body(12, .semibold))
                .foregroundStyle(P.accent)
                .textCase(.uppercase)
                .kerning(0.6)
            if section.isProse {
                BidiText(text: section.items[0], font: T.body(15), color: P.ink)
                    .lineSpacing(6)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .top, spacing: 9) {
                            Circle().fill(P.ink3).frame(width: 4, height: 4).padding(.top, 8)
                            BidiText(text: item, font: T.body(14.5), color: P.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(P.surface, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 22)
    }
}

/// "Change how it's written…" - free text appended to the prompt.
struct InstructionsSheet: View {
    @ObservedObject var templates: SummaryTemplates
    var onClose: () -> Void
    @State private var text: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Change how it's written").font(T.disp(20)).foregroundStyle(P.ink)
            Text("Extra guidance for every summary — tone, length, what to leave out. "
                 + "It is added to the prompt; it does not change which sections a "
                 + "template produces.")
                .font(T.body(12.5)).foregroundStyle(P.ink2).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(T.body(13))
                .frame(height: 130)
                .padding(8)
                .background(P.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(P.rule))
            Text("e.g. \"Keep it under 150 words. Never guess an owner for a task.\"")
                .font(T.mono(10)).foregroundStyle(P.ink3)
            HStack {
                Button("Clear") { text = "" }.buttonStyle(FlatButton(filled: false))
                Spacer()
                Button("Cancel", action: onClose).buttonStyle(FlatButton(filled: false))
                Button("Save") { templates.setInstructions(text); onClose() }
                    .buttonStyle(FlatButton(filled: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28).frame(width: 460).background(P.surface2)
        .onAppear { text = templates.instructions }
    }
}

/// "All templates…" - every template with what it actually produces, because
/// the menu only has room for a name.
struct AllTemplatesSheet: View {
    @ObservedObject var templates: SummaryTemplates
    var selected: String
    var onPick: (SummaryTemplate) -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Summary templates").font(T.disp(20)).foregroundStyle(P.ink)
                Spacer()
                Button("Done", action: onClose).buttonStyle(FlatButton(filled: false))
            }
            .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 14)
            Divider().overlay(P.rule)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(templates.all) { t in
                        Button { onPick(t) } label: { row(t) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(18)
            }
        }
        .frame(width: 520, height: 560).background(P.surface2)
    }

    private func row(_ t: SummaryTemplate) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Text(t.name).font(T.body(14, .semibold)).foregroundStyle(P.ink)
                if t.userDefined { Eyebrow(text: "yours", color: P.warn) }
                Spacer()
                if t.id == selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(P.accent)
                }
            }
            if !t.description.isEmpty {
                Text(t.description).font(T.body(12)).foregroundStyle(P.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            Text(t.sectionSummary).font(T.mono(10)).foregroundStyle(P.ink3)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(P.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(
            t.id == selected ? P.accent.opacity(0.5) : P.rule))
    }
}

/// "New template…" - a name and the sections it should produce.
struct NewTemplateSheet: View {
    @ObservedObject var templates: SummaryTemplates
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var description = ""
    @State private var rows: [SummaryTemplate.Section] = [
        .init(en: "Summary", he: "תקציר", guidance: "2-4 sentences")
    ]
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text("New template").font(T.disp(20)).foregroundStyle(P.ink)
                field("Name", text: $name, placeholder: "Retro")
                field("Description", text: $description,
                      placeholder: "What this template is for")
            }
            .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 14)
            Divider().overlay(P.rule)

            HStack {
                Text("Sections").font(T.body(12, .semibold)).foregroundStyle(P.ink2)
                    .textCase(.uppercase).kerning(0.6)
                Spacer()
                Button { rows.append(.init(en: "", he: "", guidance: "")) } label: {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(FlatButton(filled: false))
            }
            .padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 8)

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(rows.indices, id: \.self) { i in sectionRow(i) }
                }
                .padding(.horizontal, 18).padding(.bottom, 12)
            }

            if let error {
                Text(error).font(T.body(12)).foregroundStyle(P.bad)
                    .padding(.horizontal, 24).padding(.bottom, 6)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider().overlay(P.rule)
            HStack {
                Text("Both headings are required: the summary is written in the "
                     + "language of the meeting.")
                    .font(T.mono(10)).foregroundStyle(P.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(FlatButton(filled: false))
                Button("Save", action: save).buttonStyle(FlatButton(filled: true))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
        }
        .frame(width: 560, height: 600).background(P.surface2)
    }

    private func sectionRow(_ i: Int) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                TextField("Heading (English)", text: $rows[i].en)
                TextField("כותרת (עברית)", text: $rows[i].he)
                Button { rows.remove(at: i) } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.plain).foregroundStyle(P.bad)
                    .disabled(rows.count == 1)
            }
            TextField("What goes in this section", text: $rows[i].guidance)
                .font(T.body(12))
        }
        .textFieldStyle(.roundedBorder)
        .padding(12)
        .background(P.surface, in: RoundedRectangle(cornerRadius: 10))
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(T.body(11, .semibold)).foregroundStyle(P.ink3)
                .textCase(.uppercase).kerning(0.6)
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder)
        }
    }

    private func save() {
        let clean = rows
            .map { SummaryTemplate.Section(
                en: $0.en.trimmingCharacters(in: .whitespaces),
                he: $0.he.trimmingCharacters(in: .whitespaces),
                guidance: $0.guidance.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.en.isEmpty || !$0.he.isEmpty }
        // A section with only one language would put an English heading in the
        // middle of a Hebrew summary, so refuse rather than guess a translation.
        if let bad = clean.first(where: { $0.en.isEmpty || $0.he.isEmpty }) {
            error = "\"\(bad.en.isEmpty ? bad.he : bad.en)\" needs a heading in both languages."
            return
        }
        let t = SummaryTemplate(id: templates.freeID(from: name), name: name,
                                description: description, sections: clean,
                                userDefined: true)
        if let message = templates.save(t) { error = message } else { dismiss() }
    }
}
