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

    private var maxRec: Int { max(people.first?.recordings ?? 0, 1) }

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
                    Text("Names come from the invitations in bench/meetings.json, addresses stripped.")
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
                    ForEach(Array(people.enumerated()), id: \.element.id) { i, p in
                        Button { selected = p.name; listFocused = true } label: {
                            PersonRow(rank: i + 1, person: p, share: Double(p.recordings) / Double(maxRec),
                                      selected: selected == p.name, focused: listFocused)
                        }
                        .buttonStyle(.plain)
                        .id(p.name)
                        Divider().overlay(P.rule.opacity(0.7))
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
    let rank: Int
    let person: Person
    let share: Double
    let selected: Bool
    let focused: Bool
    @State private var hover = false

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(selected ? P.accent : .clear)
                .frame(width: focused && selected ? 3 : 2)
            Text(String(format: "%03d", rank))
                .font(T.mono(9)).foregroundStyle(P.ink3.opacity(0.65))
                .frame(width: 30, alignment: .trailing)
            BidiText(text: person.name, font: T.body(12.5, selected ? .semibold : .regular),
                     color: P.ink)
                .lineLimit(1)
                .padding(.leading, 9)
            Spacer(minLength: 8)
            // A short fixed track, not a full-width rule: this is a meter, and
            // a meter that spans the row reads as an underline instead.
            HStack(spacing: 0) {
                Rectangle().fill(person.recordings > 0 ? P.accent : P.rule)
                    .frame(width: max(1, 46 * share))
                Rectangle().fill(P.sunk)
            }
            .frame(width: 46, height: 3)
            VStack(alignment: .trailing, spacing: 1) {
                Text("\(person.recordings) rec")
                    .font(T.mono(10, .medium)).monospacedDigit()
                    .foregroundStyle(person.recordings > 0 ? P.accent : P.ink3)
                Text("\(person.meetings) mtg")
                    .font(T.mono(9)).foregroundStyle(P.ink3).monospacedDigit()
            }
            .frame(width: 52, alignment: .trailing)
            .padding(.leading, 9).padding(.trailing, 14)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? P.surface : (hover ? P.surface2.opacity(0.75) : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

private struct NotIndexed: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(text: "calendar not indexed")
            Text("No attendee index was found.")
                .font(T.disp(15)).foregroundStyle(P.ink)
            Text("People are read from bench/meetings.json in the checkout that owns this app. Run the calendar scanner there and reopen this window.")
                .font(T.body(12)).foregroundStyle(P.ink2).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            Text(Paths.root.appendingPathComponent("bench/meetings.json").path)
                .font(T.mono(9.5)).foregroundStyle(P.ink3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
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
                BidiText(text: person.name, font: T.disp(20), color: P.ink)
                HStack(spacing: 0) {
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
            .padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 16)
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
                    BidiText(text: meeting.title, font: T.body(12.5), color: P.ink)
                        .lineLimit(2)
                    Text("\(meeting.people.count) invited")
                        .font(T.mono(9)).foregroundStyle(P.ink3)
                }
                Spacer(minLength: 6)
                if rec != nil {
                    Pill(text: "recorded", kind: .run)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 10)
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
