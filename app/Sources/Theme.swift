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

/// Bright white and neutral gray surfaces with charcoal controls, with color reserved for status.
/// Every token resolves independently for light and dark appearance.
enum P {
    static func pair(_ light: String, _ dark: String) -> Color {
        Color(nsColor: NSColor(name: nil) { ap in
            ap.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(hex: dark) : NSColor(hex: light)
        })
    }
    static let ground     = pair("FFFFFF", "1D1D1C")
    static let surface    = pair("F7F7F7", "252524")
    static let sidebar    = pair("F5F8FC", "2D2D2B")
    static let surface2   = pair("FAFAFA", "2D2D2B")
    static let sunk       = pair("E8E8E8", "191918")
    static let ink        = pair("282828", "F1F0EC")
    static let ink2       = pair("646464", "BCBCB5")
    static let ink3       = pair("767676", "A4A49D")
    static let rule       = pair("E7E7E7", "3B3B37")
    static let ruleStrong = pair("D1D1D1", "51514B")
    static let accent     = pair("30312F", "E5E5DC")
    static let accentSoft = pair("E6E6E6", "383A33")
    static let ok         = pair("2F6F3E", "74C084")
    static let okSoft     = pair("DFEBE1", "162A1B")
    static let warn       = pair("A05F00", "DFA54A")
    static let warnSoft   = pair("F6E8D2", "302516")
    static let bad        = pair("A33A2A", "E38570")
    static let badSoft    = pair("F5E0DB", "301B16")
    static let idle       = pair("767676", "BCBCB5")
    /// Filled controls reverse their text color with the appearance.
    static let onAccent   = pair("FCFBF9", "252622")
    static let idleSoft   = pair("E8E8E8", "2D2D2B")
}

// Native typography preserves Hebrew coverage and follows macOS rendering.
enum T {
    static func mono(_ size: CGFloat, _ w: Font.Weight = .regular) -> Font {
        .system(size: size, weight: w, design: .monospaced)
    }
    static func disp(_ size: CGFloat) -> Font { .system(size: size, weight: .bold) }
    static func body(_ size: CGFloat = 13, _ w: Font.Weight = .regular) -> Font {
        .system(size: size, weight: w)
    }
}

/// Quiet section labels keep the transcript at the top of the hierarchy.
struct Eyebrow: View {
    let text: String
    var color: Color = P.ink3
    var body: some View {
        Text(text.prefix(1).uppercased() + text.dropFirst())
            .font(T.body(11, .semibold))
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
        Text(text.prefix(1).uppercased() + text.dropFirst())
            .font(T.body(10, .medium))
            .foregroundStyle(fg)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(bg, in: Capsule())
    }
}

/// Shared controls use generous hit targets and a restrained accent.
struct FlatButton: ButtonStyle {
    var tint: Color = P.accent
    var filled = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(T.body(12, .semibold))
            .foregroundStyle(filled ? P.onAccent : tint)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(filled ? tint : Color.clear, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .stroke(filled ? Color.clear : tint.opacity(0.25), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.65 : 1)
            .contentShape(Rectangle())
    }
}
