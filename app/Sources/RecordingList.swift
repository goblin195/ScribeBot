// The index column: every tape, in day order, densest thing in the app.
// Day headers are real relative labels because "Today" is the only header a
// person actually reads; everything below it is machine text in mono.
import SwiftUI

struct DayGroup: Identifiable {
    var id: Date { day }
    let day: Date
    let label: String
    let hits: [Hit]
    var seconds: TimeInterval { hits.reduce(0) { $0 + $1.rec.duration } }
}

/// "Today", "Yesterday", then the weekday for the past week, then a date.
func dayLabel(_ d: Date, now: Date = Date()) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(d) { return "Today" }
    if cal.isDateInYesterday(d) { return "Yesterday" }
    let days = cal.dateComponents([.day], from: cal.startOfDay(for: d),
                                  to: cal.startOfDay(for: now)).day ?? 0
    if days > 0 && days < 7 { return d.formatted(.dateTime.weekday(.wide)) }
    if cal.component(.year, from: d) == cal.component(.year, from: now) {
        return d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
    return d.formatted(.dateTime.day().month(.abbreviated).year())
}

/// h:mm:ss / m:ss, same shape as Recording.durationText but for a whole day.
func span(_ t: TimeInterval) -> String {
    let s = Int(t.rounded())
    return s >= 3600
        ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
        : String(format: "%d:%02d", s / 60, s % 60)
}

func groupByDay(_ hits: [Hit], now: Date = Date()) -> [DayGroup] {
    let cal = Calendar.current
    return Dictionary(grouping: hits) { cal.startOfDay(for: $0.rec.startedAt) }
        .map { DayGroup(day: $0.key, label: dayLabel($0.key, now: now),
                        hits: $0.value.sorted { $0.rec.startedAt > $1.rec.startedAt }) }
        .sorted { $0.day > $1.day }
}

struct RecordingIndex: View {
    @ObservedObject var library: Library
    @ObservedObject var recorder: Recorder
    @ObservedObject var perms: Permissions
    let hits: [Hit]
    @Binding var query: String
    @Binding var selected: String?
    @FocusState private var listFocused: Bool

    private var groups: [DayGroup] { groupByDay(hits) }
    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            ColumnHeader(title: searching ? "matches" : "recordings",
                         right: searching ? "\(hits.count)/\(library.items.count)"
                                          : "\(library.items.count)")
            if library.items.isEmpty {
                EmptyLibrary(recorder: recorder, perms: perms)
            } else if hits.isEmpty {
                NoMatches(query: query, total: library.items.count) { query = "" }
            } else {
                list
            }
        }
        .background(P.ground)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                    ForEach(groups) { g in
                        Section {
                            ForEach(g.hits) { h in
                                Button { selected = h.rec.id; listFocused = true } label: {
                                    RecordingRow(hit: h, sides: library.sides[h.rec.id] ?? .missing,
                                                 selected: selected == h.rec.id,
                                                 focused: listFocused)
                                }
                                .buttonStyle(.plain)
                                .id(h.rec.id)
                                Spacer().frame(height: 5)
                            }
                        } header: {
                            DayHeader(group: g)
                        }
                    }
                }
            }
            .focusable()
            .focused($listFocused)
            .focusEffectDisabled()
            .onMoveCommand { move($0, proxy: proxy) }
            .onChange(of: selected) { _, new in
                guard let new else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(new, anchor: .center) }
            }
        }
        .overlay(alignment: .top) {
            Rectangle().fill(listFocused ? P.accent : .clear).frame(height: 2)
        }
    }

    private func move(_ dir: MoveCommandDirection, proxy: ScrollViewProxy) {
        let flat = groups.flatMap { $0.hits.map(\.rec.id) }
        guard !flat.isEmpty else { return }
        guard let cur = selected, let i = flat.firstIndex(of: cur) else {
            selected = flat.first
            return
        }
        switch dir {
        case .up: selected = flat[max(0, i - 1)]
        case .down: selected = flat[min(flat.count - 1, i + 1)]
        default: break
        }
    }
}

// MARK: - Rows

private struct DayHeader: View {
    let group: DayGroup
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(group.label)
                .font(T.body(12, .semibold)).foregroundStyle(P.ink2)
            Rectangle().fill(P.rule).frame(height: 1).offset(y: -3)
            Text("\(group.hits.count)")
                .font(T.mono(9)).foregroundStyle(P.ink3).monospacedDigit()
        }
        .padding(.horizontal, 16).padding(.top, 15).padding(.bottom, 6)
        .background(P.ground)
    }
}

private struct RecordingRow: View {
    let hit: Hit
    let sides: Sides
    let selected: Bool
    let focused: Bool
    @State private var hover = false

    private var rec: Recording { hit.rec }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Rectangle()
                .fill(selected ? P.accent : .clear)
                .frame(width: focused && selected ? 3 : 2)
            VStack(alignment: .leading, spacing: 9) {
                BidiText(text: rec.title, font: T.body(14, selected ? .semibold : .medium),
                         color: P.ink)
                    .lineLimit(2)
                HStack(spacing: 7) {
                    Text(rec.startedAt.formatted(date: .omitted, time: .shortened))
                        .font(T.mono(10, .medium)).foregroundStyle(P.ink2).monospacedDigit()
                    Text(rec.durationText)
                        .font(T.mono(10)).foregroundStyle(P.ink3).monospacedDigit()
                    Spacer(minLength: 4)
                    SidesBadge(sides: sides)
                }
                if let s = hit.snippet {
                    HStack(alignment: .top, spacing: 6) {
                        Rectangle().fill(P.accent.opacity(0.55)).frame(width: 1.5)
                        // Mark the matched run. Search is how a meeting gets
                        // re-found, and an unmarked snippet makes the reader
                        // hunt for what they just typed.
                        let dir = baseDirection(s)
                        Text(highlighted(s, match: hit.match))
                            .font(T.body(11))
                            .lineLimit(2)
                            .multilineTextAlignment(dir == .rightToLeft ? .trailing : .leading)
                            .frame(maxWidth: .infinity,
                                   alignment: dir == .rightToLeft ? .trailing : .leading)
                            .environment(\.layoutDirection, dir)
                    }
                    .padding(.top, 1)
                }
            }
            .padding(.leading, 12).padding(.trailing, 14).padding(.vertical, 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? P.accentSoft : (hover ? P.surface2.opacity(0.75) : .clear))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? P.accent.opacity(0.2) : .clear))
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

/// Two channels, drawn as two channels. A missing side is a hole in the tape,
/// not a detail to bury in an inspector.
/// Snippet text with the search match tinted.
private func highlighted(_ s: String, match: Range<String.Index>?) -> AttributedString {
    var a = AttributedString(s)
    a.foregroundColor = P.ink2
    guard let m = match, let lo = AttributedString.Index(m.lowerBound, within: a),
          let hi = AttributedString.Index(m.upperBound, within: a) else { return a }
    a[lo..<hi].foregroundColor = P.accent
    a[lo..<hi].inlinePresentationIntent = .stronglyEmphasized
    return a
}

struct SidesBadge: View {
    let sides: Sides
    var body: some View {
        HStack(spacing: 3) {
            bar(sides.them)
            bar(sides.you)
            Text(sides.label)
                .font(T.body(10, .medium))
                .foregroundStyle(sides == .both ? P.ink3 : P.warn)
        }
        .help(sides == .both
              ? "Both sides captured — the call and your microphone, in separate files"
              : "Only one side of this conversation was captured")
    }
    private func bar(_ on: Bool) -> some View {
        Rectangle()
            .fill(on ? P.accent : P.rule)
            .frame(width: 3, height: 8)
    }
}

// MARK: - Empty states

private struct EmptyLibrary: View {
    @ObservedObject var recorder: Recorder
    @ObservedObject var perms: Permissions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: "waveform.circle")
                .font(.system(size: 42, weight: .light)).foregroundStyle(P.accent)
                .padding(.bottom, 18)
            Text("Space for your conversations")
                .font(T.disp(23)).foregroundStyle(P.ink)
            Text("Record a meeting and return to every word. Your audio and transcripts stay on this Mac.")
                .font(T.body(13)).foregroundStyle(P.ink2).lineSpacing(5).padding(.top, 10)
                .fixedSize(horizontal: false, vertical: true)
            Spacer().frame(height: 24)

            if perms.readyToRecord {
                Text("Your first recording will appear here.")
                    .font(T.body(11.5)).foregroundStyle(P.ink3).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                Button("New recording") { recorder.start() }
                    .buttonStyle(FlatButton()).padding(.top, 10)
            } else {
                Text("Allow system audio in Permissions to start recording.")
                    .font(T.body(11.5)).foregroundStyle(P.warn).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Open recordings folder") {
                NSWorkspace.shared.open(Paths.recordings)
            }
            .buttonStyle(FlatButton(filled: false)).padding(.top, 10)
            Spacer()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct Fact: View {
    let k: String, v: String, note: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(k.uppercased()).font(T.mono(9, .semibold)).tracking(1.2)
                .foregroundStyle(P.accent).frame(width: 34, alignment: .leading).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(v).font(T.mono(11, .medium)).foregroundStyle(P.ink)
                Text(note).font(T.body(11)).foregroundStyle(P.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 9)
    }
}

private struct NoMatches: View {
    let query: String
    let total: Int
    let clear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(text: "0 matches")
            BidiText(text: "Nothing in \(total) recordings says “\(query)”.",
                     font: T.body(13, .medium), color: P.ink)
            Text("Titles and full transcripts were both searched, including the text that was never shown in the live view.")
                .font(T.body(11.5)).foregroundStyle(P.ink3).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            Button("Clear search", action: clear)
                .buttonStyle(FlatButton(filled: false)).padding(.top, 4)
            Spacer()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Shared bar at the top of the index column.
struct ColumnHeader: View {
    let title: String
    let right: String
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Eyebrow(text: title)
                Spacer()
                Text(right).font(T.mono(10)).foregroundStyle(P.ink3).monospacedDigit()
            }
            .padding(.horizontal, 20).padding(.vertical, 20)
            .background(P.ground)
            Divider().overlay(P.rule)
        }
    }
}
