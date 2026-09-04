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

struct RecordingDetail: View {
    let rec: Recording
    var deletionAllowed = true
    @State private var showingDelete = false
    @State private var deleteSelection: RecordingDeletion = .both
    @State private var deleteError: String?
    @ObservedObject var library: Library
    @ObservedObject var index: MeetingIndex

    private var sides: Sides { library.sides[rec.id] ?? .missing }
    private var meeting: CalMeeting? { index.meeting(at: rec.startedAt) }
    private var lines: [Utterance] { parseTranscript(library.transcript(rec)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            masthead
            Divider().overlay(P.rule)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let m = meeting { attendees(m) }
                    transcript
                }
            }
        }
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

            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 30).padding(.top, 30).padding(.bottom, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(P.surface)
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
