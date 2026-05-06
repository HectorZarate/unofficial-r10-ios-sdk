import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

// 1024 × 1024 — Apple's single-size app icon for iOS 17+.
let size: CGFloat = 1024

// Palette: deep near-black background to match the Swing Speed
// app's icon family; cyan accent on the radar arcs for "active /
// transmitting" connotation; white text for the brand.
let bg     = CGColor(red: 0.04, green: 0.05, blue: 0.07, alpha: 1)
let arc    = CGColor(red: 0.30, green: 0.78, blue: 1.00, alpha: 1)
let text   = CGColor(red: 1.00, green: 1.00, blue: 1.00, alpha: 1)

guard let ctx = CGContext(
    data: nil,
    width: Int(size),
    height: Int(size),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { exit(1) }

// Background
ctx.setFillColor(bg)
ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

// Three concentric radar arcs in the upper portion, centered
// horizontally. Connotes the R10's Doppler radar — the device's
// signature mechanism. Arcs span ~120° (open at the bottom)
// stacked at increasing radii, fading further out.
let arcCenter = CGPoint(x: size / 2, y: size * 0.62)
let arcRadii: [(r: CGFloat, alpha: CGFloat, width: CGFloat)] = [
    (140, 1.00, 32),
    (220, 0.80, 28),
    (300, 0.55, 24),
    (380, 0.30, 20),
]

ctx.setLineCap(.round)
for (r, alpha, width) in arcRadii {
    ctx.setStrokeColor(arc.copy(alpha: alpha) ?? arc)
    ctx.setLineWidth(width)
    ctx.beginPath()
    // Arc spans ~120°: from 30° (4 o'clock-ish) through 90° (top)
    // to 150° (8 o'clock-ish) — open at the bottom, top emphasis.
    ctx.addArc(
        center: arcCenter,
        radius: r,
        startAngle: 30 * .pi / 180,
        endAngle: 150 * .pi / 180,
        clockwise: false
    )
    ctx.strokePath()
}

// "R10" wordmark below the arcs, centered. Rounded heavy face
// to match the Swing Speed icon family.
let label = "R10"
let fontSize: CGFloat = 360
let font: CTFont = {
    // Prefer the rounded-heavy face; fall back to system heavy if
    // not registered (rendering-time concern, not a build error).
    if let rounded = CTFontCreateWithNameAndOptions(
        "SFProRounded-Black" as CFString,
        fontSize, nil, []
    ) as CTFont? {
        return rounded
    }
    return CTFontCreateUIFontForLanguage(.system, fontSize, nil)
        ?? CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
}()

// Use CT attribute keys directly so this script doesn't need
// AppKit (which is GUI-only on macOS) — pure Foundation +
// CoreText + CoreGraphics is enough for `swift` to run.
let attributes: [CFString: Any] = [
    kCTFontAttributeName: font,
    kCTForegroundColorAttributeName: text,
]
let attributed = CFAttributedStringCreate(
    kCFAllocatorDefault,
    label as CFString,
    attributes as CFDictionary
)!
let line = CTLineCreateWithAttributedString(attributed)
let lineBounds = CTLineGetImageBounds(line, ctx)

// Center horizontally; sit text below the arc cluster.
let textY = size * 0.18
let textX = (size - lineBounds.width) / 2 - lineBounds.origin.x
ctx.textPosition = CGPoint(x: textX, y: textY)
CTLineDraw(line, ctx)

// Output PNG
guard let cgImage = ctx.makeImage() else { exit(1) }
let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
guard let dest = CGImageDestinationCreateWithURL(
    outputURL as CFURL,
    UTType.png.identifier as CFString,
    1, nil
) else { exit(1) }
CGImageDestinationAddImage(dest, cgImage, nil)
guard CGImageDestinationFinalize(dest) else { exit(1) }
print("Wrote \(outputURL.path)")
