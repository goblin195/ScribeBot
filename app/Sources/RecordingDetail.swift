// One tape, read. The masthead is fixed so the title and the numbers never
// scroll away from the text they describe; everything below it scrolls.
import SwiftUI

enum Side: String {
    case them = "Them", you = "You"
    var color: Color { self == .them ? P.accent : P.warn }
}

struct Utterance: Identifiable {
    let id: Int
    let side: Side?
    let text: String
}

/// Transcript lines are written as "Them: …" / "You: …" by Recorder.finalize;
/// anything unprefixed is a live-preview line from before that split existed.
func parseTranscript(_ raw: String) -> [Utterance] {
    raw.split(separator: "\n", omittingEmptySubsequences: true).enumerated().map { i, l in
        let line = String(l)
        for side in [Side.them, .you] where line.lowercased().hasPrefix(side.rawValue.lowercased() + ":") {
            return Utterance(id: i, side: side,
                             text: String(line.dropFirst(side.rawValue.count + 1))
                                .trimmingCharacters(in: .whitespaces))
        }
        return Utterance(id: i, side: nil, text: line)
    }
}

/// Which half of a recording is on screen. The transcript is what the app
/// produced; the summary is what a model made of it. They are read for
/// different reasons, so they are two views of one recording rather than two
/// panels competing for the same scroll.
enum DetailTab: String { case transcription, summary }

struct RecordingDetail: View {
    let rec: Recording
    var deletionAllowed = true
    @State private var showingDelete = false
    @State private var deleteSelection: RecordingDeletion = .both
    @State private var deleteError: String?
    @ObservedObject var library: Library
    @ObservedObject var index: MeetingIndex

    @State private var tab: DetailTab = .transcription
    @State private var templateID = SummaryTemplates.defaultID
    @StateObject private var summarizer = Summarizer()
    @ObservedObject private var templates = SummaryTemplates.shared
    @State private var editingInstructions = false
    @State private var browsingTemplates = false
    @State private var creatingTemplate = false
    @State private var copied = false
    @State private var copyReset: Task<Void, Never>?

    private var sides: Sides { library.sides[rec.id] ?? .missing }
    private var meeting: CalMeeting? { index.meeting(at: rec.startedAt) }
    private var lines: [Utterance] { parseTranscript(library.transcript(rec)) }
    private var template: SummaryTemplate { templates.template(templateID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            masthead
            Divider().overlay(P.rule)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let m = meeting { attendees(m) }
                    switch tab {
                    case .transcription: transcript
                    case .summary: summaryPane
                    }
                }
            }
        }
        .onAppear(perform: loadForRecording)
        .onChange(of: rec.id) { loadForRecording() }
        .sheet(isPresented: $editingInstructions) { instructionsSheet }
        .sheet(isPresented: $browsingTemplates) { allTemplatesSheet }
        .sheet(isPresented: $creatingTemplate) { NewTemplateSheet(templates: templates) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(P.ground)
        .sheet(isPresented: $showingDelete) {
            VStack(alignment: .leading, spacing: 20) {
                Text("Delete call files?").font(T.disp(22)).foregroundStyle(P.ink)
                BidiText(text: rec.title, font: T.body(14), color: P.ink2)
                Picker("Delete", selection: $deleteSelection) {
                    ForEach(RecordingDeletion.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.radioGroup)
                Text(deleteSelection.explanation)
                    .font(T.body(13)).foregroundStyle(P.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                Text("You can recover the files from Trash.")
                    .font(T.body(12)).foregroundStyle(P.ink2)
                HStack {
                    Spacer()
                    Button("Cancel") { showingDelete = false }
                        .keyboardShortcut(.cancelAction)
                    Button("Move to Trash", role: .destructive) {
                        guard deletionAllowed else { return }
                        showingDelete = false
                        do { try library.delete(rec, selection: deleteSelection) }
                        catch { deleteError = error.localizedDescription }
                    }
                    .disabled(!deletionAllowed)
                }
            }
            .padding(28).frame(width: 420).background(P.surface)
        }
        .alert("Could not finish deleting", isPresented: Binding(
            get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
                Button("OK") { deleteError = nil }
            } message: {
                Text((deleteError ?? "") + " Any files already moved can be recovered from Trash.")
            }
    }

    // MARK: - Masthead

    private var masthead: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Eyebrow(text: rec.startedAt.formatted(
                    .dateTime.weekday(.wide).day().month(.wide).year()))
                Spacer()
                SidesBadge(sides: sides)
            }
            BidiText(text: rec.title, font: T.disp(28), color: P.ink)
                .fixedSize(horizontal: false, vertical: true)

            FlowLayout(spacing: 18) {
                Stat(k: "started", v: rec.startedAt.formatted(date: .omitted, time: .shortened))
                Stat(k: "duration", v: rec.durationText)
                Stat(k: "sources", v: "\(sides == .both ? 2 : sides == .missing ? 0 : 1) of 2",
                     tint: sides == .both ? P.ink : sides == .missing ? P.bad : P.warn)

            }
            .padding(.top, 3)

            HStack(spacing: 8) {
                Button { deleteSelection = .both; showingDelete = true } label: {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(FlatButton(tint: P.bad, filled: false))
                .disabled(!deletionAllowed)
                .help(deletionAllowed ? "Choose which call files to delete" : "Wait for recording and transcription to finish")
                Button("Reveal in Finder") { library.reveal(rec) }
                    .buttonStyle(FlatButton(filled: false))
                Spacer(minLength: 12)
                viewToggle
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 30).padding(.top, 30).padding(.bottom, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(P.sidebar)
    }

    // MARK: - Transcription / Summary toggle

    private func loadForRecording() {
        templateID = SummaryTemplates.selectedID(for: rec.id)
        summarizer.loadCached(rec.id, template: templateID)
        copyReset?.cancel(); copied = false
    }

    private func choose(_ t: SummaryTemplate) {
        templateID = t.id
        SummaryTemplates.select(t.id, for: rec.id)
        tab = .summary
        // Each template caches its own file, so switching back to one already
        // generated is instant rather than another minute of model time.
        summarizer.cancel()
        summarizer.loadCached(rec.id, template: t.id)
    }

    private func generate() {
        summarizer.run(id: rec.id, template: templateID,
                       instructions: templates.instructions)
    }

    @ViewBuilder private var templateMenu: some View {
        Button { editingInstructions = true } label: {
            Label("Change how it's written…", systemImage: "pencil.circle")
        }
        Divider()
        Section("Templates") {
            ForEach(templates.all) { t in
                Button { choose(t) } label: {
                    if t.id == templateID { Label(t.name, systemImage: "checkmark") }
                    else { Text(t.name) }
                }
            }
        }
        Divider()
        Button { browsingTemplates = true } label: {
            Label("All templates…", systemImage: "square.grid.2x2")
        }
        Button { creatingTemplate = true } label: {
            Label("New template…", systemImage: "plus")
        }
    }

    private var viewToggle: some View {
        HStack(spacing: 3) {
            Button { tab = .transcription } label: {
                Label("Transcription", systemImage: "text.alignleft")
            }
            .buttonStyle(Segment(active: tab == .transcription))

            // The label switches view, the chevron opens the template menu.
            // A Menu with primaryAction: renders no chevron here, which left
            // the whole template list unreachable.
            HStack(spacing: 5) {
                Button { tab = .summary } label: {
                    Label("Summary", systemImage: "sparkles")
                        .labelStyle(.titleAndIcon)
                        .imageScale(.small)
                }
                .buttonStyle(.plain)
                Menu {
                    templateMenu
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 12)
                .help("Summary template: \(template.name)")
            }
            .font(T.body(12.5, .semibold))
            .foregroundStyle(tab == .summary ? P.surface : P.ink2)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(tab == .summary ? P.ink : .clear, in: Capsule())
            .fixedSize()
        }
        .padding(3)
        .background(P.surface2, in: Capsule())
        .overlay(Capsule().strokeBorder(P.rule, lineWidth: 1))
    }

    // MARK: - Summary

    @ViewBuilder private var summaryPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text(template.name).font(T.body(15, .semibold)).foregroundStyle(P.ink2)
                if case .ready(_, true) = summarizer.state {
                    Eyebrow(text: "saved")
                }
                Spacer()
                if case let .ready(s, _) = summarizer.state, !s.isEmpty {
                    // The label is the whole confirmation: a summary is read
                    // in place, and a banner here would push it down the page.
                    Button(copied ? "Copied" : "Copy") { copy(s) }
                        .buttonStyle(FlatButton(filled: false))
                }
                if case .running = summarizer.state {
                    Button("Cancel") { summarizer.cancel() }
                        .buttonStyle(FlatButton(filled: false))
                } else {
                    Button(hasSummary ? "Regenerate" : "Summarise", action: generate)
                        .buttonStyle(FlatButton(filled: !hasSummary))
                        .disabled(lines.isEmpty)
                }
            }
            .padding(.horizontal, 30).padding(.top, 18)

            switch summarizer.state {
            case .running, .failed:
                SummaryStatus(summarizer: summarizer)
            case let .ready(s, _):
                if !s.isEmpty { SummaryDocument(summary: s) }
            case .idle:
                VStack(alignment: .leading, spacing: 6) {
                    Eyebrow(text: "no summary yet")
                    Text(lines.isEmpty
                         ? "There is no transcript to summarise yet."
                         : "\(template.name) — \(template.sectionSummary). Runs on this Mac through Ollama; nothing is uploaded.")
                        .font(T.body(12)).foregroundStyle(P.ink2).lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(22).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 8)
    }

    private func copy(_ s: Summary) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s.markdown, forType: .string)
        copied = true
        copyReset?.cancel()
        copyReset = Task {
            try? await Task.sleep(for: .seconds(1.8))
            if !Task.isCancelled { copied = false }
        }
    }

    private var hasSummary: Bool {
        if case .ready = summarizer.state { return true }
        return false
    }

    // MARK: - Sheets

    private var instructionsSheet: some View {
        InstructionsSheet(templates: templates) { editingInstructions = false }
    }

    private var allTemplatesSheet: some View {
        AllTemplatesSheet(templates: templates, selected: templateID,
                          onPick: { t in choose(t); browsingTemplates = false },
                          onClose: { browsingTemplates = false })
    }

    // MARK: - Calendar

    private func attendees(_ m: CalMeeting) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Eyebrow(text: "Invited participants (\(m.people.count))", color: P.accent)
                Rectangle().fill(P.rule).frame(height: 1)
                if !m.location.isEmpty {
                    BidiText(text: m.location, font: T.mono(9), color: P.ink3)
                        .fixedSize()
                }
            }
            FlowLayout(spacing: 5) {
                ForEach(m.people, id: \.self) { name in
                    BidiText(text: name, font: T.body(12), color: P.ink2)
                        .fixedSize()
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(P.surface2, in: Capsule())
                }
            }
            if m.title != rec.title {
                Text("calendar: \(m.title)").font(T.mono(9)).foregroundStyle(P.ink3)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(P.sunk.opacity(0.55))
        .overlay(alignment: .bottom) { Divider().overlay(P.rule) }
    }

    // MARK: - Transcript

    @ViewBuilder private var transcript: some View {
        if lines.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Eyebrow(text: "no transcript")
                Text(sides == .missing
                     ? "The audio for this recording is gone, so there is nothing left to transcribe."
                     : "The transcript is not available yet. Your audio is saved on this Mac.")
                    .font(T.body(12)).foregroundStyle(P.ink2).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                Text("Transcript").font(T.body(15, .semibold)).foregroundStyle(P.ink2)
                    .padding(.horizontal, 30).padding(.top, 18)
                ForEach(lines) { u in UtteranceRow(u: u) }
            }
            .padding(.vertical, 8)
        }
    }
}

private struct UtteranceRow: View {
    let u: Utterance
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: u.side == .you ? "person.fill" : "waveform")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background((u.side?.color ?? P.ink3).opacity(0.12), in: Circle())
                Text(u.side?.rawValue ?? "Speaker")
                    .font(T.body(12, .semibold))
            }
            .foregroundStyle(u.side?.color ?? P.ink2)
            BidiText(text: u.text, font: T.body(16), color: P.ink)
                .lineSpacing(7)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(P.surface, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 30)
        .padding(.bottom, 2)
    }
}

private struct Stat: View {
    let k: String, v: String
    var tint: Color = P.ink
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Eyebrow(text: k)
            Text(v).font(T.mono(11.5, .medium)).foregroundStyle(tint).monospacedDigit()
        }
        .frame(minWidth: 78, alignment: .leading)
    }
}

/// Attendee lists run to eighteen names; they have to wrap. Small enough to
/// not be worth a dependency. ponytail: single-axis, no alignment options.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > width && x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += sz.width + spacing
            rowHeight = max(rowHeight, sz.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            rowHeight = max(rowHeight, sz.height)
        }
    }
}
