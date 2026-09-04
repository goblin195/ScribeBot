// Committed text, then the unstable tail underneath it in a dimmer weight.
// Hebrew is right-to-left and routinely carries English technical terms, so
// every line gets its own base direction (see RTL.swift) rather than one
// alignment forced on the whole document.
//
// The same rows render here and in TranscriptDetailView, so a line looks the
// same live as it does a week later.
import SwiftUI

struct TranscriptView: View {
    @ObservedObject var recorder: Recorder

    /// ponytail: test hook, twin of SCRIBEBOT_DEMO — opens this window straight
    /// onto a saved recording so the reader can be screenshotted headlessly.
    private var detail: Recording? {
        guard let id = ProcessInfo.processInfo.environment["SCRIBEBOT_DETAIL"] else { return nil }
        return recorder.library.items.first { $0.id == id }
    }

    var body: some View {
        Group {
            if let rec = detail {
                TranscriptDetailView(recording: rec, library: recorder.library)
            } else {
                VStack(spacing: 0) {
                    header
                    Divider().overlay(P.rule)
                    body_
                }
                .background(P.ground)
            }
        }
        .frame(minWidth: 520, minHeight: 420)
    }

    private var header: some View {
        HStack(spacing: 10) {
            if recorder.isRecording { RecDot() }
            Eyebrow(text: recorder.isRecording ? "Live transcript" : "transcript",
                    color: recorder.isRecording ? P.bad : P.ink3)
            Spacer()
            if recorder.isRecording {
                Text(clock(recorder.elapsed))
                    .font(T.mono(11, .medium)).foregroundStyle(P.ink2).monospacedDigit()
            }
            Text("\(recorder.committed.count) lines")
                .font(T.mono(10)).foregroundStyle(P.ink3)
        }
        .padding(.horizontal, 22).padding(.vertical, 13)
        .background(P.surface2)
    }

    /// The live buffer, read through the same parser the saved file uses: the
    /// microphone transcriber labels its lines `You:`, the system tap does not.
    private var lines: [TranscriptLine] {
        Transcript.parse(recorder.committed.joined(separator: "\n"))
    }

    @ViewBuilder private var body_: some View {
        if recorder.committed.isEmpty && recorder.provisional.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "text.alignright")
                    .font(.system(size: 22, weight: .light)).foregroundStyle(P.ink3)
                Text("No transcript yet.").font(T.body(13)).foregroundStyle(P.ink2)
                Text("Start a recording from the menu bar.\nYour conversation will appear here as you speak.")
                    .font(T.body(11.5)).foregroundStyle(P.ink3)
                    .multilineTextAlignment(.center).lineSpacing(3)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let rows = lines
            let attributed = Transcript.isAttributed(rows)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { line in
                            if attributed,
                               line.id == 0 || rows[line.id - 1].speaker != line.speaker {
                                TurnHeader(speaker: line.speaker)
                            }
                            TranscriptRow(line: line, attributed: attributed)
                        }
                        if recorder.isFinalizing {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Re-transcribing the recording for accuracy…")
                                    .font(T.body(12)).foregroundStyle(P.ink2)
                            }
                            .padding(.top, 6).padding(.leading, 60)
                        }
                        if !recorder.provisional.isEmpty {
                            Provisional(text: recorder.provisional)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.vertical, 14)
                }
                .onChange(of: recorder.committed.count) {
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
        }
    }
}

/// The unstable tail: same column, lighter weight, tinted so it is obvious the
/// words can still change.
private struct Provisional: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text("···")
                .font(T.mono(9.5)).foregroundStyle(P.accent)
                .frame(width: 34, alignment: .trailing)
                .padding(.top, 5)
            Rectangle().fill(P.accent.opacity(0.35))
                .frame(width: 2).padding(.leading, 12).padding(.trailing, 12)
            BidiText(text: text, font: T.body(14.5, .light), color: P.ink3)
                .padding(.trailing, 26)
        }
        .padding(.vertical, 4)
        .background(P.accentSoft.opacity(0.35))
    }
}
