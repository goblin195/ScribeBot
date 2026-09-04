// Renders the app icon at every size macOS wants, then iconutil packs the .icns.
//
// The mark is a level meter read right-to-left: the tallest bar sits on the
// right, where a Hebrew sentence begins. The product exists because Hebrew
// speech carries English terms, and the icon says that rather than showing a
// generic microphone.
import AppKit
import CoreGraphics
import Foundation

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let out = URL(fileURLWithPath: "Scribebot.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

// cool slate ground, teal accent - the same palette as the rest of the product
func slate(_ dark: Bool) -> CGColor {
    dark ? CGColor(red: 0.055, green: 0.078, blue: 0.075, alpha: 1)
         : CGColor(red: 0.086, green: 0.098, blue: 0.102, alpha: 1)
}
let teal   = CGColor(red: 0.33, green: 0.75, blue: 0.69, alpha: 1)
let tealDim = CGColor(red: 0.33, green: 0.75, blue: 0.69, alpha: 0.42)

// Bar heights as fractions of the drawable height. Tallest on the RIGHT.
let bars: [CGFloat] = [0.18, 0.30, 0.22, 0.46, 0.34, 0.62, 0.44, 0.86, 0.58]

func render(_ px: Int) -> CGImage? {
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                              bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    let s = CGFloat(px)

    // rounded-square ground, macOS-style corner radius
    let inset = s * 0.055
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = CGPath(roundedRect: rect, cornerWidth: s * 0.225,
                      cornerHeight: s * 0.225, transform: nil)
    ctx.addPath(path); ctx.setFillColor(slate(true)); ctx.fillPath()

    // a single hairline keeps it from reading as a flat blob at large sizes
    if px >= 128 {
        ctx.addPath(path)
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.07))
        ctx.setLineWidth(max(1, s * 0.004)); ctx.strokePath()
    }

    let n = CGFloat(bars.count)
    let field = rect.width * 0.62
    let gap = field / (n * 2.1)
    let w = (field - gap * (n - 1)) / n
    let originX = rect.midX - field / 2
    let midY = rect.midY

    for (i, h) in bars.enumerated() {
        let barH = rect.height * h
        let x = originX + CGFloat(i) * (w + gap)
        let r = CGRect(x: x, y: midY - barH / 2, width: w, height: barH)
        // the two rightmost bars carry the accent; the rest recede
        ctx.setFillColor(i >= bars.count - 2 ? teal : tealDim)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: w / 2,
                           cornerHeight: w / 2, transform: nil))
        ctx.fillPath()
    }
    return ctx.makeImage()
}

for px in sizes {
    guard let img = render(px) else { continue }
    let rep = NSBitmapImageRep(cgImage: img)
    guard let data = rep.representation(using: .png, properties: [:]) else { continue }
    let scale = px / 2
    try? data.write(to: out.appendingPathComponent("icon_\(px)x\(px).png"))
    if sizes.contains(scale) {
        try? data.write(to: out.appendingPathComponent("icon_\(scale)x\(scale)@2x.png"))
    }
}
print("iconset written")
