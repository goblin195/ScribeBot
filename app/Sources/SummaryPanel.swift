// The Hebrew summary, sitting above the transcript it came from.
//
// Idle shows nothing at all — the panel only exists once there is something to
// say. Running shows a clock and where the work is happening, because a local
// 14B model takes the better part of a minute and silence reads as a hang.
import SwiftUI

/// Progress and failure, pinned above the scroll view: a run whose only sign of
/// life is off-screen reads exactly like a hang.
struct SummaryStatus: View {
    @ObservedObject var summarizer: Summarizer

    var body: some View {
        switch summarizer.state {
        case .running: running
        case let .failed(message, hint): failure(message, hint)
        default: EmptyView()
        }
    }

    private var running: some View {
        Band(tone: P.accent) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 10) {
                    Eyebrow(text: "summarising", color: P.accent)
                    Text(clock(summarizer.elapsed))
                        .font(T.mono(11, .medium)).monospacedDigit()
                        .foregroundStyle(P.ink2)
                    Text("typically 30–60s")
                        .font(T.mono(10)).foregroundStyle(P.ink3)
                    Spacer()
                }
                ProgressView().progressViewStyle(.linear).tint(P.accent)
                Text("ollama · localhost:11434 · the transcript never leaves this Mac")
                    .font(T.mono(9.5)).foregroundStyle(P.ink3)
            }
        }
    }

    private func failure(_ message: String, _ hint: String) -> some View {
        Band(tone: P.bad) {
            VStack(alignment: .leading, spacing: 6) {
                Eyebrow(text: "summary failed", color: P.bad)
                Text(message).font(T.body(12.5)).foregroundStyle(P.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text(hint).font(T.mono(10)).foregroundStyle(P.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

}

/// The finished summary, which is content and therefore scrolls with the
/// transcript it summarises.
struct SummaryPanel: View {
    @ObservedObject var summarizer: Summarizer

    var body: some View {
        if case let .ready(summary, cached) = summarizer.state {
            content(summary, cached: cached)
        }
    }

    private func content(_ s: Summary, cached: Bool) -> some View {
        Band(tone: P.accent) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Eyebrow(text: "summary", color: P.accent)
                    Spacer()
                    Text(cached ? "cached" : "just generated")
                        .font(T.mono(9)).tracking(1.1).foregroundStyle(P.ink3)
                }
                if !s.abstract.isEmpty {
                    Section(index: "01", title: "תקציר")
                    BidiText(text: s.abstract, font: T.body(13.5), color: P.ink)
                        .padding(.top, 2)
                }
                if !s.decisions.isEmpty {
                    Section(index: "02", title: "החלטות")
                    items(s.decisions)
                }
                if !s.tasks.isEmpty {
                    Section(index: "03", title: "משימות")
                    items(s.tasks)
                }
            }
        }
    }

    private func items(_ rows: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                HStack(alignment: .top, spacing: 10) {
                    Text(String(format: "%02d", i + 1))
                        .font(T.mono(9.5)).foregroundStyle(P.ink3)
                        .padding(.top, 3)
                    BidiText(text: row, font: T.body(13), color: P.ink)
                }
            }
        }
        .padding(.top, 3)
    }
}

/// Hebrew heading with a mono index — the sections are numbered machinery, the
/// heading itself is prose, so they get different faces.
private struct Section: View {
    let index: String, title: String
    var body: some View {
        HStack(spacing: 8) {
            Text(index).font(T.mono(9.5, .medium)).foregroundStyle(P.accent)
            Text(title).font(T.body(12, .semibold)).foregroundStyle(P.ink)
            Rectangle().fill(P.rule).frame(height: 1)
        }
        .padding(.top, 13).padding(.bottom, 3)
    }
}

/// A flat block with one coloured edge — no card, no shadow, no rounded box.
private struct Band<Content: View>: View {
    let tone: Color
    @ViewBuilder let content: Content
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Rectangle().fill(tone).frame(width: 2)
            content
                .padding(.horizontal, 18).padding(.vertical, 13)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(P.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(P.rule).frame(height: 1) }
        .padding(.bottom, 6)
    }
}
