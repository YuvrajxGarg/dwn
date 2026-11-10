// Renders Dwn's icons from the "dwn↓" wordmark.
//   swift make_icon.swift icon <out.iconset>   macOS app icon: dark tile, white wordmark
//   swift make_icon.swift tray <out dir>       Windows tray: download symbol in white and black, 1x and 2x
import AppKit
import CoreText

/// The wordmark: "dwn" in a heavy grotesk set tight, then the drop arrow on the baseline.
/// Drawn with CoreGraphics (y-up). Returns the drawn width.
@discardableResult
func drawWordmark(_ cg: CGContext, x: CGFloat, baseline: CGFloat, size: CGFloat, color: CGColor, draw: Bool = true) -> CGFloat {
    let font = NSFont.systemFont(ofSize: size, weight: .black)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .kern: -size * 0.055, .foregroundColor: NSColor(cgColor: color)!]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: "dwn", attributes: attrs))
    let textW = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) - size * 0.055
    let gap = size * 0.07
    let aw = size * 0.36, ah = size * 0.56
    if draw {
        cg.saveGState()
        cg.textPosition = CGPoint(x: x, y: baseline)
        CTLineDraw(line, cg)
        cg.restoreGState()
        cg.addPath(arrowPath(in: CGRect(x: x + textW + gap, y: baseline, width: aw, height: ah)))
        cg.setFillColor(color)
        cg.fillPath()
    }
    return textW + gap + aw
}

/// Rounded stem flowing into a solid head, pointing down (y-up coordinates).
func arrowPath(in r: CGRect) -> CGPath {
    let p = CGMutablePath()
    let w = r.width, h = r.height
    let half = w * 0.17
    let headTop = r.minY + h * 0.54
    p.move(to: CGPoint(x: r.midX - half, y: headTop))
    p.addLine(to: CGPoint(x: r.midX - half, y: r.maxY - half))
    p.addArc(center: CGPoint(x: r.midX, y: r.maxY - half), radius: half, startAngle: .pi, endAngle: 0, clockwise: true)
    p.addLine(to: CGPoint(x: r.midX + half, y: headTop))
    p.addLine(to: CGPoint(x: r.maxX, y: headTop))
    p.addLine(to: CGPoint(x: r.midX, y: r.minY))
    p.addLine(to: CGPoint(x: r.minX, y: headTop))
    p.closeSubpath()
    return p
}

func bitmap(_ w: Int, _ h: Int, _ body: (CGContext) -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    body(ctx.cgContext)
    NSGraphicsContext.current = nil
    return rep.representation(using: .png, properties: [:])!
}

/// App icon: near-black tile on the macOS icon grid, white wordmark centred.
func appIcon(_ px: Int) -> Data {
    bitmap(px, px) { cg in
        let s = CGFloat(px)
        let inset = s * 0.098
        let tile = CGRect(x: inset, y: inset * 1.15, width: s - inset * 2, height: s - inset * 2)
        let radius = tile.width * 0.225
        let tilePath = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)

        cg.saveGState()
        cg.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.45).cgColor)
        cg.addPath(tilePath)
        cg.setFillColor(NSColor(white: 0.07, alpha: 1).cgColor)
        cg.fillPath()
        cg.restoreGState()

        cg.saveGState()
        cg.addPath(tilePath)
        cg.clip()
        let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [NSColor(white: 0.17, alpha: 1).cgColor, NSColor(white: 0.05, alpha: 1).cgColor] as CFArray,
                              locations: [0, 1])!
        cg.drawLinearGradient(grad, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
        cg.restoreGState()

        cg.addPath(CGPath(roundedRect: tile.insetBy(dx: s * 0.002, dy: s * 0.002), cornerWidth: radius, cornerHeight: radius, transform: nil))
        cg.setStrokeColor(NSColor.white.withAlphaComponent(0.12).cgColor)
        cg.setLineWidth(max(1, s * 0.004))
        cg.strokePath()

        // Small sizes get a bigger wordmark so it stays readable.
        let size = tile.width * (px <= 32 ? 0.36 : 0.30)
        let white = NSColor(white: 0.97, alpha: 1).cgColor
        let w = drawWordmark(cg, x: 0, baseline: 0, size: size, color: white, draw: false)
        let capCenter = size * 0.36   // roughly the middle of the x-height
        drawWordmark(cg, x: tile.midX - w / 2, baseline: tile.midY - capCenter, size: size, color: white)
    }
}

/// Download symbol (arrow into an open tray) on an 18-unit grid, y-up.
/// Same drawing as DownloadGlyph in the app's StatusItem.swift.
func downloadGlyph(_ cg: CGContext, size: CGFloat, color: CGColor) {
    let k = size / 18
    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * k, y: (18 - y) * k) }
    cg.setStrokeColor(color)
    cg.setLineWidth(1.75 * k)
    cg.setLineCap(.round)
    cg.setLineJoin(.round)
    cg.move(to: pt(9, 2.6)); cg.addLine(to: pt(9, 11.2))
    cg.move(to: pt(5.4, 7.8)); cg.addLine(to: pt(9, 11.4)); cg.addLine(to: pt(12.6, 7.8))
    cg.move(to: pt(3, 11.6)); cg.addLine(to: pt(3, 13.6))
    cg.addQuadCurve(to: pt(4.8, 15.4), control: pt(3, 15.4))
    cg.addLine(to: pt(13.2, 15.4))
    cg.addQuadCurve(to: pt(15, 13.6), control: pt(15, 15.4))
    cg.addLine(to: pt(15, 11.6))
    cg.strokePath()
}

/// Tray icon for Windows: the download symbol, no background.
func trayIcon(_ px: Int, white: Bool) -> Data {
    bitmap(px, px) { cg in
        downloadGlyph(cg, size: CGFloat(px), color: white ? NSColor.white.cgColor : NSColor.black.cgColor)
    }
}

let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "icon"
let out = args.count > 2 ? args[2] : (mode == "icon" ? "AppIcon.iconset" : ".")
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
if mode == "tray" {
    for (name, px) in [("", 16), ("@2x", 32)] {
        try! trayIcon(px, white: true).write(to: URL(fileURLWithPath: "\(out)/tray-white\(name).png"))
        try! trayIcon(px, white: false).write(to: URL(fileURLWithPath: "\(out)/tray-black\(name).png"))
    }
} else {
    for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                       ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
        try! appIcon(px).write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
    }
}
print("wrote \(out)")
