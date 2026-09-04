// Past recordings. Title from the calendar when it could name the meeting,
// otherwise the timestamp.
import SwiftUI

struct MeetingsView: View {
    @ObservedObject var library: Library
    @State private var selected: Recording?

    var body: some View {
        HSplitView {
            list.frame(minWidth: 290, idealWidth: 330)
            detail.frame(minWidth: 300)
        }
        .background(P.ground)
        .frame(minWidth: 680, minHeight: 420)
        .onAppear { library.reload() }
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack {
                Eyebrow(text: "recordings")
                Spacer()
                Text("\(library.items.count)").font(T.mono(10)).foregroundStyle(P.ink3)
            }
            .padding(.horizontal, 18).padding(.vertical, 13)
            .background(P.surface2)
            Divider().overlay(P.rule)

            if library.items.isEmpty {
                VStack(spacing: 8) {
                    Text("Nothing recorded yet.").font(T.body(12.5)).foregroundStyle(P.ink2)
                    Text("Recordings land in ~/Library/Application Support/Scribebot")
                        .font(T.mono(9.5)).foregroundStyle(P.ink3)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(library.items) { r in
                            Button { selected = r } label: {
                                RecordingRow(rec: r, selected: selected?.id == r.id)
                            }
                            .buttonStyle(.plain)
                            Divider().overlay(P.rule)
                        }
                    }
                }
            }
        }
        .background(P.ground)
    }

    @ViewBuilder private var detail: some View {
        if let r = selected {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 7) {
                    Eyebrow(text: r.startedAt.formatted(date: .complete, time: .omitted))
                    Text(r.title).font(T.disp(19)).tracking(-0.3).foregroundStyle(P.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        Stat(k: "started", v: r.startedAt.formatted(date: .omitted, time: .shortened))
                        Stat(k: "duration", v: r.durationText)
                        Stat(k: "audio", v: "16 kHz mono")
                    }
                    .padding(.top, 4)
                    Button("Reveal in Finder") { library.reveal(r) }
                        .buttonStyle(FlatButton(filled: false))
                        .padding(.top, 6)
                }
                .padding(20)
                Divider().overlay(P.rule)
                ScrollView {
                    let text = library.transcript(r)
                    if text.isEmpty {
                        Text("No transcript was saved for this recording.")
                            .font(T.body(12)).foregroundStyle(P.ink3)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(20)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(text.split(separator: "\n").enumerated()), id: \.offset) { _, l in
                                BidiText(text: String(l), font: T.body(13.5), color: P.ink)
                            }
                        }
                        .padding(20)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            Text("Select a recording.")
                .font(T.body(12.5)).foregroundStyle(P.ink3)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct Stat: View {
    let k: String, v: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Eyebrow(text: k)
            Text(v).font(T.mono(11.5)).foregroundStyle(P.ink)
        }
    }
}

private struct RecordingRow: View {
    let rec: Recording
    let selected: Bool
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Rectangle().fill(selected ? P.accent : Color.clear).frame(width: 2)
            VStack(alignment: .leading, spacing: 4) {
                BidiText(text: rec.title, font: T.body(13, .medium), color: P.ink)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(rec.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(T.mono(10)).foregroundStyle(P.ink3)
                    Text("·").foregroundStyle(P.ink3)
                    Text(rec.durationText).font(T.mono(10)).foregroundStyle(P.ink2)
                }
            }
            Spacer()
        }
        .padding(.trailing, 16).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? P.surface : (hover ? P.surface2 : Color.clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}
