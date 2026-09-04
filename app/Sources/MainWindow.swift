// The real window, as opposed to the menu-bar panel: three columns of
// decreasing chrome — control, index, content. Nothing here is a card. The
// structure is carried by rules and by the rhythm of the left gutter, so that
// scanning down the index column reads like a log rather than a feed.
import SwiftUI

enum Pane: String, CaseIterable {
    case recordings, people
    var icon: String {
        switch self {
        case .recordings: return "waveform"
        case .people: return "person.2"
        }
    }
}

struct MainWindowView: View {
    @ObservedObject var library: Library
    @ObservedObject var recorder: Recorder
    @ObservedObject var perms: Permissions
    @StateObject private var index = MeetingIndex.shared

    @State private var pane: Pane = .recordings
    @State private var query = (ProcessInfo.processInfo.environment["SCRIBEBOT_SEARCH"] ?? "")
    @State private var selectedRec: String?
    @State private var selectedPerson: String?
    @FocusState private var searchFocused: Bool

    private var hits: [Hit] { library.hits(query) }
    private var people: [Person] {
        let all = index.people(matching: library.items)
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 196, idealWidth: 220, maxWidth: 290)
            index_.frame(minWidth: 268, idealWidth: 330, maxWidth: 520)
            detail.frame(minWidth: 360, idealWidth: 630)
        }
        .background(P.ground)
        // Ideal, not just minimum: SwiftUI sizes a Window scene from the
        // content's ideal size, and three columns at their minimum is a
        // window that clips its own detail pane.
        .frame(minWidth: 860, idealWidth: 1180, minHeight: 520, idealHeight: 760)
        .onAppear {
            library.reload()
            if selectedRec == nil { selectedRec = library.items.first?.id }
        }
        .background(shortcuts)
    }

    /// ⌘F and ⌘K both land in the search field; ⌘1/⌘2 switch panes.
    private var shortcuts: some View {
        ZStack {
            Button("") { searchFocused = true }.keyboardShortcut("f", modifiers: .command)
            Button("") { searchFocused = true }.keyboardShortcut("k", modifiers: .command)
            Button("") { pane = .recordings }.keyboardShortcut("1", modifiers: .command)
            Button("") { pane = .people }.keyboardShortcut("2", modifiers: .command)
        }
        .opacity(0).frame(width: 0, height: 0)
    }

    // MARK: - Column 1

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Eyebrow(text: "scribebot", color: P.accent)
                Spacer()
                Pill(text: recorder.isRecording ? "rec" : "idle",
                     kind: recorder.isRecording ? .run : .idle)
            }
            .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 13)

            RecordAction(recorder: recorder, perms: perms)
                .padding(.horizontal, 14).padding(.bottom, 14)

            SearchField(query: $query, focused: $searchFocused,
                        placeholder: pane == .people ? "filter people" : "title + transcript")
                .padding(.horizontal, 14).padding(.bottom, 16)

            Eyebrow(text: "library").padding(.horizontal, 17).padding(.bottom, 6)
            NavRow(pane: .recordings, title: "Recordings", key: "1",
                   count: library.items.count, active: pane == .recordings) { pane = .recordings }
            NavRow(pane: .people, title: "People", key: "2",
                   count: index.meetings.isEmpty ? nil : people.count,
                   active: pane == .people) { pane = .people }

            Spacer(minLength: 12)
            Divider().overlay(P.rule)
            footer
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(P.surface2)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 5) {
            FootStat(k: "tapes", v: "\(library.items.count)")
            FootStat(k: "captured", v: totalDuration)
            FootStat(k: "calendar", v: index.meetings.isEmpty
                     ? "not indexed" : "\(index.meetings.count) meetings")
            Text("~/Library/Application Support/Scribebot")
                .font(T.mono(8.5)).foregroundStyle(P.ink3.opacity(0.8))
                .lineLimit(1).truncationMode(.head)
                .padding(.top, 3)
        }
        .padding(.horizontal, 17).padding(.vertical, 13)
    }

    private var totalDuration: String {
        let s = Int(library.items.reduce(0) { $0 + $1.duration })
        return String(format: "%dh %02dm", s / 3600, (s / 60) % 60)
    }

    // MARK: - Column 2

    @ViewBuilder private var index_: some View {
        switch pane {
        case .recordings:
            RecordingIndex(library: library, recorder: recorder, perms: perms,
                           hits: hits, query: $query, selected: $selectedRec)
        case .people:
            PeopleIndex(people: people, query: query, selected: $selectedPerson,
                        indexed: !index.meetings.isEmpty)
        }
    }

    // MARK: - Column 3

    @ViewBuilder private var detail: some View {
        switch pane {
        case .recordings:
            if let r = library.items.first(where: { $0.id == selectedRec }) {
                RecordingDetail(rec: r, library: library, index: index)
                    .id(r.id)
            } else {
                Blank(line: hits.isEmpty && !query.isEmpty
                      ? "No recording matches the query."
                      : "Select a recording from the index.")
            }
        case .people:
            if let p = people.first(where: { $0.name == selectedPerson }) {
                PersonDetail(person: p, index: index, library: library) { rec in
                    pane = .recordings
                    query = ""
                    selectedRec = rec
                }
                .id(p.name)
            } else {
                Blank(line: "Select a person to see the meetings they were invited to.")
            }
        }
    }
}

// MARK: - Sidebar pieces

private struct RecordAction: View {
    @ObservedObject var recorder: Recorder
    @ObservedObject var perms: Permissions

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button { recorder.isRecording ? recorder.stop() : recorder.start() } label: {
                HStack(spacing: 7) {
                    Image(systemName: recorder.isRecording ? "stop.fill" : "record.circle")
                        .font(.system(size: 11, weight: .semibold))
                    Text(recorder.isRecording ? "STOP & SAVE" : "START CAPTURE")
                    Spacer()
                    if recorder.isRecording {
                        Text(clock(recorder.elapsed)).monospacedDigit()
                    }
                }
            }
            .buttonStyle(FlatButton(tint: recorder.isRecording ? P.bad : P.accent))
            .disabled(!perms.readyToRecord && !recorder.isRecording)
            .opacity(perms.readyToRecord || recorder.isRecording ? 1 : 0.45)

            if recorder.isRecording {
                LevelMeter(level: recorder.level)
            } else if !perms.readyToRecord {
                Text("System audio not granted")
                    .font(T.mono(9)).foregroundStyle(P.warn)
            }
        }
    }
}

struct SearchField: View {
    @Binding var query: String
    var focused: FocusState<Bool>.Binding
    let placeholder: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(focused.wrappedValue ? P.accent : P.ink3)
            TextField(placeholder, text: $query)
                .textFieldStyle(.plain)
                .font(T.mono(11))
                .foregroundStyle(P.ink)
                .focused(focused)
                .onExitCommand { query = ""; focused.wrappedValue = false }
            if query.isEmpty {
                Text("⌘K").font(T.mono(9)).foregroundStyle(P.ink3.opacity(0.7))
            } else {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                }
                .buttonStyle(.plain).foregroundStyle(P.ink3)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(P.surface)
        .overlay(Rectangle().stroke(focused.wrappedValue ? P.accent : P.rule,
                                    lineWidth: focused.wrappedValue ? 1.5 : 1))
    }
}

private struct NavRow: View {
    let pane: Pane
    let title: String
    let key: String
    var count: Int?
    let active: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Rectangle().fill(active ? P.accent : .clear).frame(width: 2, height: 15)
                Image(systemName: pane.icon).font(.system(size: 11))
                    .foregroundStyle(active ? P.accent : P.ink2).frame(width: 15)
                Text(title).font(T.body(12.5, active ? .semibold : .regular))
                    .foregroundStyle(active ? P.ink : P.ink2)
                Spacer()
                if let count {
                    Text("\(count)").font(T.mono(10))
                        .foregroundStyle(active ? P.ink2 : P.ink3)
                }
                Text("⌘\(key)").font(T.mono(9)).foregroundStyle(P.ink3.opacity(hover ? 0.9 : 0.45))
            }
            .padding(.trailing, 15).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(active ? P.surface : (hover ? P.sunk.opacity(0.6) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct FootStat: View {
    let k: String, v: String
    var body: some View {
        HStack(spacing: 0) {
            Text(k.uppercased()).font(T.mono(9)).tracking(1)
                .foregroundStyle(P.ink3)
            Spacer(minLength: 6)
            Text(v).font(T.mono(9.5, .medium)).foregroundStyle(P.ink2)
        }
    }
}

struct Blank: View {
    let line: String
    var body: some View {
        Text(line)
            .font(T.body(12.5)).foregroundStyle(P.ink3)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(P.ground)
    }
}
