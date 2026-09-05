// People, from the calendar rather than from the audio. Diarization guesses who
// spoke; an invitation knows who was asked. The count that matters is how many
// recordings a person's meetings actually produced — most names produce none.
import SwiftUI

struct PeopleIndex: View {
    let people: [Person]
    let query: String
    @Binding var selected: String?
    let indexed: Bool
    @FocusState private var listFocused: Bool


    var body: some View {
        VStack(spacing: 0) {
            ColumnHeader(title: "people", right: "\(people.count)")
            if !indexed {
                NotIndexed()
            } else if people.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Eyebrow(text: "0 matches")
                    BidiText(text: "No attendee is named “\(query)”.",
                             font: T.body(13, .medium), color: P.ink)
                    Text("Search uses names from your calendar invitations.")
                        .font(T.body(11.5)).foregroundStyle(P.ink3).lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                list
            }
        }
        .background(P.ground)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(people) { p in
                        Button { selected = p.name; listFocused = true } label: {
                            PersonRow(person: p, selected: selected == p.name)
                        }
                        .buttonStyle(.plain)
                        .id(p.name)
                        Spacer().frame(height: 5)
                    }
                }
            }
            .focusable()
            .focused($listFocused)
            .focusEffectDisabled()
            .onMoveCommand { dir in
                let names = people.map(\.name)
                guard let cur = selected, let i = names.firstIndex(of: cur) else {
                    selected = names.first; return
                }
                if dir == .up { selected = names[max(0, i - 1)] }
                if dir == .down { selected = names[min(names.count - 1, i + 1)] }
            }
            .onChange(of: selected) { _, new in
                guard let new else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(new, anchor: .center) }
            }
        }
        .overlay(alignment: .top) {
            Rectangle().fill(listFocused ? P.accent : .clear).frame(height: 2)
        }
    }
}

private struct PersonRow: View {
    let person: Person
    let selected: Bool
    @State private var hover = false

    private var initials: String {
        person.name.split(separator: " ").prefix(2).compactMap { $0.first }
            .map(String.init).joined().uppercased()
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(initials)
                .font(T.body(12, .semibold)).foregroundStyle(P.accent)
                .frame(width: 36, height: 36)
                .background(P.accentSoft, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                BidiText(text: person.name, font: T.body(14, .medium), color: P.ink)
                    .lineLimit(2)
                Text("\(person.meetings) meetings")
                    .font(T.body(11)).foregroundStyle(P.ink2)
            }
            if person.recordings > 0 {
                Label("\(person.recordings)", systemImage: "waveform")
                    .font(T.body(11, .medium)).foregroundStyle(P.accent)
                    .accessibilityLabel("\(person.recordings) recordings")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? P.accentSoft : (hover ? P.surface2 : .clear),
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(selected ? P.accent.opacity(0.2) : .clear))
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

private struct NotIndexed: View {
    /// An installed copy has no checkout behind it, so the old text here -
    /// "read from bench/meetings.json in the checkout that owns this app, run
    /// the calendar scanner there" - was an instruction the reader could not
    /// follow, printed above a path inside the app bundle. A user who installs
    /// the DMG should never be shown either. This is an empty state, not an
    /// error: People fills in from the meetings Scribebot records.
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(text: "nobody yet")
            Text("People appear as you record meetings.")
                .font(T.disp(15)).foregroundStyle(P.ink)
            Text("Scribebot lists the people in your calendar events for the calls "
                 + "it records. Grant calendar access in Settings to name meetings "
                 + "and their attendees.")
                .font(T.body(12)).foregroundStyle(P.ink2).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Calendar settings") {
                NotificationCenter.default.post(name: .openSettings, object: nil,
                                                userInfo: ["page": SettingsPage.calendar.rawValue])
            }
            .buttonStyle(FlatButton(filled: false))
            Spacer()
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Detail

struct PersonDetail: View {
    let person: Person
    @ObservedObject var index: MeetingIndex
    @ObservedObject var library: Library
    let openRecording: (String) -> Void

    private var meetings: [CalMeeting] { index.meetings(with: person.name) }
    /// meeting id -> the recording it produced, if any.
    private var tapes: [Int: Recording] {
        var out: [Int: Recording] = [:]
        for r in library.items {
            if let m = index.meeting(at: r.startedAt) { out[m.id] = r }
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Eyebrow(text: "attendee")
                BidiText(text: person.name, font: T.disp(28), color: P.ink)
                FlowLayout(spacing: 18) {
                    Stat(k: "meetings", v: "\(person.meetings)")
                    Stat(k: "recorded", v: "\(person.recordings)",
                         tint: person.recordings > 0 ? P.accent : P.ink3)
                    if let latest = meetings.first {
                        Stat(k: latest.start > Date() ? "next" : "last seen",
                             v: latest.start.formatted(.dateTime.day().month(.abbreviated).year()))
                    }
                }
                .padding(.top, 3)
            }
            .padding(.horizontal, 30).padding(.top, 30).padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(P.surface)

            Divider().overlay(P.ruleStrong)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(meetings) { m in
                        MeetingRow(meeting: m, rec: tapes[m.id], open: openRecording)
                        Divider().overlay(P.rule.opacity(0.7))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(P.ground)
    }
}

private struct MeetingRow: View {
    let meeting: CalMeeting
    let rec: Recording?
    let open: (String) -> Void
    @State private var hover = false

    var body: some View {
        Button {
            if let rec { open(rec.id) }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(meeting.start.formatted(.dateTime.day().month(.abbreviated)))
                        .font(T.mono(10, .medium)).foregroundStyle(P.ink2)
                    Text(meeting.start.formatted(date: .omitted, time: .shortened))
                        .font(T.mono(9)).foregroundStyle(P.ink3).monospacedDigit()
                }
                .frame(width: 54, alignment: .trailing)
                VStack(alignment: .leading, spacing: 3) {
                    BidiText(text: meeting.title, font: T.body(14), color: P.ink)
                        .lineLimit(2)
                    Text("\(meeting.people.count) invited")
                        .font(T.body(11)).foregroundStyle(P.ink2)
                }
                Spacer(minLength: 6)
                if rec != nil {
                    Pill(text: "recorded", kind: .run)
                }
            }
            .padding(.horizontal, 30).padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hover && rec != nil ? P.surface2.opacity(0.8) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(rec == nil)
        .onHover { hover = $0 }
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
        .frame(minWidth: 88, alignment: .leading)
    }
}
