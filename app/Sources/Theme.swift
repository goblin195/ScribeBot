// Visual language lifted from docs/progress.html: cool slate neutrals, one teal
// accent, monospace for anything that is a label rather than prose.
import SwiftUI
import AppKit

extension NSColor {
    convenience init(hex: String) {
        var v: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&v)
        self.init(srgbRed: CGFloat((v >> 16) & 255) / 255,
                  green: CGFloat((v >> 8) & 255) / 255,
                  blue: CGFloat(v & 255) / 255, alpha: 1)
    }
}

/// One token = one light/dark pair, resolved per appearance like the CSS vars.
enum P {
    static func pair(_ light: String, _ dark: String) -> Color {
        Color(nsColor: NSColor(name: nil) { ap in
            ap.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(hex: dark) : NSColor(hex: light)
        })
    }
    static let ground     = pair("F6F7F6", "0F1413")
    static let surface    = pair("FFFFFF", "161B1A")
    static let surface2   = pair("ECEFEE", "1D2422")
    static let sunk       = pair("E3E7E5", "111716")
    static let ink        = pair("16191A", "E7EDEB")
    static let ink2       = pair("57615E", "94A09D")
    static let ink3       = pair("828C89", "6E7A77")
    static let rule       = pair("D7DCDA", "2A3230")
    static let ruleStrong = pair("BFC7C4", "3A4442")
    static let accent     = pair("0D6E63", "54BFB1")
    static let accentSoft = pair("DCEAE7", "16302D")
    static let ok         = pair("2F6F3E", "74C084")
    static let okSoft     = pair("DFEBE1", "162A1B")
    static let warn       = pair("A05F00", "DFA54A")
    static let warnSoft   = pair("F6E8D2", "302516")
    static let bad        = pair("A33A2A", "E38570")
    static let badSoft    = pair("F5E0DB", "301B16")
    static let idle       = pair("7E8885", "7E8885")
    /// Label on a filled accent button. White reads on the dark teal of the
    /// light theme and disappears on the light teal of the dark one.
    static let onAccent   = pair("FFFFFF", "07100E")
    static let idleSoft   = pair("E6E9E8", "1E2523")
}

// IBM Plex is not installed on this machine, so the roles are mapped onto the
// system faces that carry the same intent: monospace for machine labels, a
// tightly tracked bold for display, SF's Hebrew coverage for prose.
enum T {
    static func mono(_ size: CGFloat, _ w: Font.Weight = .regular) -> Font {
        .system(size: size, weight: w, design: .monospaced)
    }
    static func disp(_ size: CGFloat) -> Font { .system(size: size, weight: .bold) }
    static func body(_ size: CGFloat = 13, _ w: Font.Weight = .regular) -> Font {
        .system(size: size, weight: w)
    }
}

/// The uppercase mono kicker used above every block in progress.html.
struct Eyebrow: View {
    let text: String
    var color: Color = P.ink3
    var body: some View {
        Text(text.uppercased())
            .font(T.mono(9.5, .medium))
            .tracking(1.5)
            .foregroundStyle(color)
    }
}

/// Small status chip. Same six variants as the .pill classes.
struct Pill: View {
    enum Kind { case ok, warn, bad, idle, run }
    let text: String
    let kind: Kind
    private var fg: Color {
        switch kind {
        case .ok: return P.ok
        case .warn: return P.warn
        case .bad: return P.bad
        case .idle: return P.idle
        case .run: return P.accent
        }
    }
    private var bg: Color {
        switch kind {
        case .ok: return P.okSoft
        case .warn: return P.warnSoft
        case .bad: return P.badSoft
        case .idle: return P.idleSoft
        case .run: return P.accentSoft
        }
    }
    var body: some View {
        Text(text.uppercased())
            .font(T.mono(9, .medium)).tracking(1.1)
            .foregroundStyle(fg)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(bg, in: RoundedRectangle(cornerRadius: 2))
    }
}

/// Flat teal button — no capsule, no gradient, matches the doc's hard edges.
struct FlatButton: ButtonStyle {
    var tint: Color = P.accent
    var filled = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(T.mono(11, .medium)).tracking(0.6)
            .foregroundStyle(filled ? P.onAccent : tint)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(filled ? tint : Color.clear, in: RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3)
                .stroke(filled ? Color.clear : tint.opacity(0.5), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.65 : 1)
            .contentShape(Rectangle())
    }
}
