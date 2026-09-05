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

/// The whole summary as one card. A single long run under a heading is a
/// paragraph, anything else is a list: a template's sections are not all the
/// same shape - "Summary" is prose and "Blockers" is a list.
///
/// This used to be a card per `## heading`, each heading and each bullet its
/// own SwiftUI `Text`. SwiftUI text selection is per-`Text`: a drag could only
/// ever select the one box it started in and ⌘A selected nothing at all, which
/// is what the user hit. One text view is the only way to get a single
/// selection across the whole summary - and it is also the only way to get
/// real RTL, where the heading, the bullet marker and the wrapped continuation
/// lines all sit on the right edge rather than being individually re-aligned.
struct SummaryDocument: View {
    let summary: Summary
    var body: some View {
        // No colorScheme rebuild here on purpose: NSColor(P.ink) is a dynamic
        // NSCustomDynamicColor that resolves at draw time, so the theme
        // follows on its own. An earlier version rebuilt the string on a
        // colorScheme change, which did nothing anyway - two identically built
        // attributed strings compare equal, so updateNSView returned early -
        // and that equality is load-bearing: it is what stops an unrelated
        // redraw from throwing away the user's selection.
        SelectableText(content: Self.attributed(
            summary, rtl: dominantDirection(summary.markdown) == .rightToLeft))
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(P.surface, in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 22)
    }

    private static let hangingIndent: CGFloat = 15

    static func attributed(_ s: Summary, rtl: Bool) -> NSAttributedString {
        let out = NSMutableAttributedString()

        func paragraph(before: CGFloat, lineSpacing: CGFloat,
                       hanging: CGFloat = 0) -> NSParagraphStyle {
            let p = NSMutableParagraphStyle()
            // Set the alignment explicitly rather than leaving it .natural:
            // .natural follows the app's UI language, not this text's script,
            // so a Hebrew summary in an English UI came out left-aligned.
            p.baseWritingDirection = rtl ? .rightToLeft : .leftToRight
            p.alignment = rtl ? .right : .left
            p.paragraphSpacingBefore = out.length == 0 ? 0 : before
            p.lineSpacing = lineSpacing
            p.headIndent = hanging
            if hanging > 0 {
                p.tabStops = [NSTextTab(textAlignment: .natural, location: hanging)]
            }
            return p
        }

        func add(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
                 color: NSColor, kern: CGFloat = 0, style: NSParagraphStyle) {
            if out.length > 0 { out.append(NSAttributedString(string: "\n")) }
            out.append(NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: weight),
                .foregroundColor: color,
                .kern: kern,
                .paragraphStyle: style,
            ]))
        }

        let ink = NSColor(P.ink), accent = NSColor(P.accent), marker = NSColor(P.ink3)
        if !s.preamble.isEmpty {
            add(s.preamble, size: 15, color: ink,
                style: paragraph(before: 0, lineSpacing: 6))
        }
        for section in s.sections {
            // Hebrew has no case, so uppercasing only affects English headings -
            // which is exactly the treatment the cards used to give them.
            add(section.title.uppercased(), size: 12, weight: .semibold,
                color: accent, kern: 0.6, style: paragraph(before: 22, lineSpacing: 0))
            if section.isProse {
                add(section.items[0], size: 15, color: ink,
                    style: paragraph(before: 10, lineSpacing: 6))
            } else {
                for (i, item) in section.items.enumerated() {
                    let start = out.length
                    add("•\t" + item, size: 14.5, color: ink,
                        style: paragraph(before: i == 0 ? 10 : 8,
                                         lineSpacing: 3, hanging: hangingIndent))
                    // The marker is furniture, the item is content; the cards
                    // made the same distinction with a dimmer dot. `add`
                    // separates blocks with a newline, so skip it.
                    out.addAttribute(.foregroundColor, value: marker,
                                     range: NSRange(location: start == 0 ? 0 : start + 1,
                                                    length: 1))
                }
            }
        }
        return out
    }
}

/// TextKit's "as tall as it needs to be". Spelled out because a bare
/// `.greatestFiniteMagnitude` is ambiguous between CGFloat and Double here.
private let unbounded: CGFloat = .greatestFiniteMagnitude

/// A read-only text view sized to its content, because SwiftUI has no
/// multi-paragraph selectable text of its own (see SummaryDocument).
private struct SelectableText: NSViewRepresentable {
    let content: NSAttributedString

    func makeNSView(context: Context) -> NSTextView {
        let v = NSTextView(frame: NSRect.zero)
        // The height below is measured through NSLayoutManager, so pin the
        // view to TextKit 1 here rather than letting the first measurement
        // trip the fallback in the middle of a layout pass.
        _ = v.layoutManager
        v.textContainer?.lineFragmentPadding = 0
        v.textContainer?.widthTracksTextView = false
        v.isEditable = false
        v.isSelectable = true
        v.drawsBackground = false
        v.textContainerInset = NSSize(width: 0, height: 0)
        v.isHorizontallyResizable = false
        v.isVerticallyResizable = true
        return v
    }

    func updateNSView(_ v: NSTextView, context: Context) {
        guard v.textStorage?.isEqual(to: content) != true else { return }
        v.textStorage?.setAttributedString(content)
    }

    /// Inside a ScrollView nothing else will give the text view a height - the
    /// scroll view offers it infinite space and it collapses - so measure the
    /// wrapped text at the width SwiftUI is proposing.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView v: NSTextView,
                      context: Context) -> CGSize? {
        guard let container = v.textContainer, let layout = v.layoutManager else { return nil }
        let width = proposal.width ?? 0
        guard width > 0, width < .infinity else { return nil }
        container.size = NSSize(width: width, height: unbounded)
        layout.ensureLayout(for: container)
        return CGSize(width: width, height: ceil(layout.usedRect(for: container).height))
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
