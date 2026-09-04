import SwiftUI

/// Base paragraph direction for a line, from its first strong directional
/// character — the same rule the Unicode bidi algorithm uses (P2/P3).
/// A Hebrew sentence carrying English terms stays RTL; an English sentence
/// carrying a Hebrew name stays LTR. Getting this wrong is what flips
/// trailing punctuation to the wrong end of the line.
func baseDirection(_ s: String) -> LayoutDirection {
    for u in s.unicodeScalars {
        switch u.value {
        case 0x0041...0x005A, 0x0061...0x007A, 0x00C0...0x02B8:
            return .leftToRight
        case 0x0590...0x08FF,        // Hebrew, Arabic, Syriac, Thaana, N'Ko…
             0xFB1D...0xFDFF, 0xFE70...0xFEFF:
            return .rightToLeft
        default: continue
        }
    }
    return .leftToRight
}

/// A transcript line laid out in its own base direction.
struct BidiText: View {
    let text: String
    var font: Font = T.body(15)
    var color: Color = P.ink

    var body: some View {
        let dir = baseDirection(text)
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .lineSpacing(4)
            .multilineTextAlignment(dir == .rightToLeft ? .trailing : .leading)
            .frame(maxWidth: .infinity,
                   alignment: dir == .rightToLeft ? .trailing : .leading)
            .environment(\.layoutDirection, dir)
            .textSelection(.enabled)
    }
}
