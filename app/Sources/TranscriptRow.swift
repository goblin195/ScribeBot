// One line of transcript, and the turn header above the first line of a turn.
//
// "You" and "Them" are told apart the way a printed interview does it — a mono
// speaker rule above the turn and a coloured hairline down the side — not with
// two columns of chat bubbles. The prose column stays exactly where it is for
// both speakers, so a long Hebrew paragraph keeps its measure either way.
import SwiftUI

/// `YOU ─────────────────` above the first line of a turn.
struct TurnHeader: View {
    let speaker: Speaker
    var body: some View {
        HStack(spacing: 8) {
            Text(speaker.label)
                .font(T.mono(9, .semibold)).tracking(1.6)
                .foregroundStyle(speaker == .you ? P.accent : P.ink3)
            Rectangle()
                .fill(speaker == .you ? P.accent.opacity(0.35) : P.rule)
                .frame(height: 1)
        }
        .padding(.leading, 62).padding(.trailing, 26)
        .padding(.top, 14).padding(.bottom, 5)
    }
}

struct TranscriptRow: View {
    let line: TranscriptLine
    let attributed: Bool
    /// Every hit inside this line, plus which one (if any) is the active match.
    var hits: [Range<String.Index>] = []
    var active: Range<String.Index>? = nil
    var isActiveLine = false

    private var accentRule: Color {
        guard attributed else { return P.rule }
        return line.speaker == .you ? P.accent.opacity(0.55) : P.ruleStrong.opacity(0.6)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(String(format: "%03d", line.id + 1))
                .font(T.mono(9.5))
                .foregroundStyle(isActiveLine ? P.accent : P.ink3.opacity(0.65))
                .frame(width: 34, alignment: .trailing)
                .padding(.top, 5)
            Rectangle().fill(accentRule)
                .frame(width: attributed ? 2 : 1)
                .padding(.leading, 12).padding(.trailing, 12)
            HighlightedText(text: line.text, hits: hits, active: active)
                .padding(.trailing, 26)
        }
        .padding(.vertical, 4)
        .background(isActiveLine ? P.accentSoft.opacity(0.5) : Color.clear)
    }
}

/// BidiText's rule (base direction from the first strong character) applied to
/// an attributed string, so search hits can be painted without losing RTL.
struct HighlightedText: View {
    let text: String
    var hits: [Range<String.Index>] = []
    var active: Range<String.Index>? = nil
    var font: Font = T.body(14.5)
    var color: Color = P.ink

    private var string: AttributedString {
        var a = AttributedString(text)
        a.foregroundColor = color
        let n = a.characters.count
        for r in hits {
            let lo = text.distance(from: text.startIndex, to: r.lowerBound)
            let hi = text.distance(from: text.startIndex, to: r.upperBound)
            guard lo < hi, hi <= n else { continue }
            let s = a.index(a.startIndex, offsetByCharacters: lo)
            let e = a.index(a.startIndex, offsetByCharacters: hi)
            let isActive = r == active
            a[s..<e].backgroundColor = isActive ? P.accent : P.accentSoft
            a[s..<e].foregroundColor = isActive ? Color.white : P.ink
        }
        return a
    }

    var body: some View {
        let dir = baseDirection(text)
        Text(string)
            .font(font)
            .lineSpacing(4)
            .multilineTextAlignment(dir == .rightToLeft ? .trailing : .leading)
            .frame(maxWidth: .infinity,
                   alignment: dir == .rightToLeft ? .trailing : .leading)
            .environment(\.layoutDirection, dir)
            .textSelection(.enabled)
    }
}
