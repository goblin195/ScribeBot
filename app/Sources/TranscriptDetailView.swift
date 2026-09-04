// A saved recording, read in full: speaker-attributed transcript, in-page
// search, the Hebrew summary, and export.
//
// Text comes from the Library (which caches, and holds the demo fixtures), so
// the shell only has to hand over the Recording it selected.
import SwiftUI

struct TranscriptDetailView: View {
    let recording: Recording
    @ObservedObject var library: Library

    @StateObject private var summarizer = Summarizer()
    @State private var lines: [TranscriptLine] = []
    @State private var query = ""
    @State private var hits: [Match] = []
    @State private var cursor = 0
    @State private var notice: String?
    @FocusState private var searchFocused: Bool

    private var attributed: Bool { Transcript.isAttributed(lines) }
    private var activeHit: Match? { hits.indices.contains(cursor) ? hits[cursor] : nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(P.rule)
            searchBar
            Divider().overlay(P.rule)
            if let notice {
                Banner(text: notice) { self.notice = nil }
                Divider().overlay(P.rule)
            }
            SummaryStatus(summarizer: summarizer)
                .fixedSize(horizontal: false, vertical: true)
            transcript
        }
        .background(P.ground)
        .frame(minWidth: 460, minHeight: 380)
        .onAppear(perform: load)
        .onChange(of: recording.id) { load() }
    }

    private func load() {
        lines = Transcript.parse(library.transcript(recording))
        // ponytail: test hook, twin of SCRIBEBOT_DEMO — seeds the find field so
        // highlighting can be screenshotted without driving the keyboard.
        query = ProcessInfo.processInfo.environment["SCRIBEBOT_FIND"] ?? ""
        hits = Transcript.search(lines, query); cursor = 0; notice = nil
        summarizer.loadCached(recording.id)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 9) {
            Eyebrow(text: recording.startedAt.formatted(date: .complete, time: .omitted))
            BidiText(text: recording.title, font: T.disp(20), color: P.ink)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 0) {
                Stat("started", recording.startedAt.formatted(date: .omitted, time: .shortened))
                Stat("length", recording.durationText)
                Stat("lines", "\(lines.count)")
                Stat("words", "\(wordCount)")
                Stat("speakers", attributed ? "you · them" : "unlabelled")
            }
            .padding(.top, 3)
            actions.padding(.top, 5)
        }
        .padding(.horizontal, 22).padding(.top, 16).padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(P.surface2)
    }

    private var wordCount: Int {
        lines.reduce(0) { $0 + $1.text.split(separator: " ").count }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button(summaryButtonTitle) {
                if case .running = summarizer.state { summarizer.cancel() }
                else { summarizer.run(id: recording.id) }
            }
            .buttonStyle(FlatButton())
            .disabled(lines.isEmpty)

            Menu {
                ForEach(ExportFormat.allCases) { f in
                    Button(f.label) { export(f) }
                }
            } label: {
                Text("EXPORT").font(T.mono(11, .medium)).tracking(0.6)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 74)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .overlay(RoundedRectangle(cornerRadius: 3)
                .stroke(P.accent.opacity(0.5), lineWidth: 1))
            .foregroundStyle(P.accent)
            .disabled(lines.isEmpty)

            Button("COPY TRANSCRIPT") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(Transcript.plainText(lines), forType: .string)
                notice = "Copied \(lines.count) lines to the clipboard."
            }
            .buttonStyle(FlatButton(filled: false))
            .disabled(lines.isEmpty)

            Button("REVEAL") { library.reveal(recording) }
            .buttonStyle(FlatButton(tint: P.ink3, filled: false))
            Spacer()
        }
    }

    private var summaryButtonTitle: String {
        switch summarizer.state {
        case .running: return "CANCEL"
        case .ready: return "RE-SUMMARISE"
        default: return "SUMMARISE"
        }
    }

    private func export(_ f: ExportFormat) {
        Task {
            if let err = await TranscriptExport.run(f, lines: lines,
                                                    duration: recording.duration,
                                                    name: recording.title,
                                                    wav: Paths.recordings
                                                        .appendingPathComponent(recording.wav)) {
                notice = err
            }
        }
    }

    // MARK: - Search

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10.5, weight: .medium)).foregroundStyle(P.ink3)
            TextField("find in transcript", text: $query)
                .textFieldStyle(.plain)
                .font(T.body(12.5))
                .foregroundStyle(P.ink)
                .focused($searchFocused)
                .onSubmit { step(+1) }
                .onChange(of: query) {
                    hits = Transcript.search(lines, query)
                    cursor = 0
                }
            if !query.isEmpty {
                Text(hits.isEmpty ? "no matches" : "\(cursor + 1)/\(hits.count)")
                    .font(T.mono(10)).monospacedDigit()
                    .foregroundStyle(hits.isEmpty ? P.bad : P.ink2)
                Stepper2(back: { step(-1) }, fwd: { step(+1) }, enabled: !hits.isEmpty)
                Button { query = ""; hits = [] } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain).foregroundStyle(P.ink3)
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 9)
        .background(P.ground)
        // ⌘F puts the caret in the find field; the button is only a shortcut host.
        .overlay {
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0).frame(width: 0, height: 0)
        }
    }

    private func step(_ d: Int) {
        guard !hits.isEmpty else { return }
        cursor = (cursor + d + hits.count) % hits.count
    }

    // MARK: - Body

    @ViewBuilder private var transcript: some View {
        if lines.isEmpty {
            VStack(spacing: 9) {
                Image(systemName: "text.alignright")
                    .font(.system(size: 20, weight: .light)).foregroundStyle(P.ink3)
                Text("No transcript was saved for this recording.")
                    .font(T.body(12.5)).foregroundStyle(P.ink2)
                Text("The audio is still on disk — reveal it to re-run the transcriber.")
                    .font(T.mono(10)).foregroundStyle(P.ink3)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        SummaryPanel(summarizer: summarizer)
                        ForEach(lines) { line in
                            if attributed, startsTurn(line) {
                                TurnHeader(speaker: line.speaker)
                            }
                            TranscriptRow(line: line,
                                          attributed: attributed,
                                          hits: hitRanges[line.id] ?? [],
                                          active: activeHit?.line == line.id
                                              ? activeHit?.range : nil,
                                          isActiveLine: activeHit?.line == line.id)
                                .id(line.id)
                        }
                        Color.clear.frame(height: 24)
                    }
                    .padding(.top, 4)
                }
                .onChange(of: cursor) { scroll(proxy) }
                .onChange(of: hits.count) { scroll(proxy) }
            }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard let h = activeHit else { return }
        withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(h.line, anchor: .center) }
    }

    /// Hits bucketed by line so a row does not scan the whole result set.
    private var hitRanges: [Int: [Range<String.Index>]] {
        Dictionary(grouping: hits, by: \.line).mapValues { $0.map(\.range) }
    }

    private func startsTurn(_ line: TranscriptLine) -> Bool {
        line.id == 0 || lines[line.id - 1].speaker != line.speaker
    }
}

// MARK: - Small parts

private struct Stat: View {
    let k: String, v: String
    init(_ k: String, _ v: String) { self.k = k; self.v = v }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Eyebrow(text: k)
            Text(v).font(T.mono(11)).monospacedDigit().foregroundStyle(P.ink)
        }
        .frame(minWidth: 74, alignment: .leading)
    }
}

/// Prev/next as one hairline-divided pair, in keeping with the flat chrome.
private struct Stepper2: View {
    let back: () -> Void, fwd: () -> Void, enabled: Bool
    var body: some View {
        HStack(spacing: 0) {
            arrow("chevron.up", back)
            Rectangle().fill(P.rule).frame(width: 1, height: 14)
            arrow("chevron.down", fwd)
        }
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(P.rule, lineWidth: 1))
        .opacity(enabled ? 1 : 0.4)
        .disabled(!enabled)
    }
    private func arrow(_ name: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: name)
                .font(.system(size: 8, weight: .bold))
                .frame(width: 20, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(P.ink2)
    }
}

/// Transient one-line message strip — export errors, copy confirmations.
struct Banner: View {
    let text: String
    let dismiss: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Text(text).font(T.mono(10.5)).foregroundStyle(P.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain).foregroundStyle(P.ink3)
        }
        .padding(.horizontal, 22).padding(.vertical, 7)
        .background(P.accentSoft.opacity(0.6))
    }
}
