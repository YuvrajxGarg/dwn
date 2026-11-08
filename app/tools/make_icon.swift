// Renders Dwn's app icon (dark tile + lime drop arrow) into an .iconset.
// Usage: swift make_icon.swift <out.iconset>
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func arrowPath(in r: CGRect) -> CGPath {
    let p = CGMutablePath()
    let w = r.width, h = r.height
    // y-up: one continuous outline, stem on top, head pointing down.
    let half = w * 0.17
    let headTop = r.maxY - h * 0.46
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

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext

    // macOS icon grid: the tile is ~80% of the canvas, with a soft shadow.
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
                          colors: [NSColor(white: 0.19, alpha: 1).cgColor, NSColor(white: 0.055, alpha: 1).cgColor] as CFArray,
                          locations: [0, 1])!
    cg.drawLinearGradient(grad, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
    // Lime glow behind the arrow.
    let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [NSColor(red: 0.8, green: 1, blue: 0.3, alpha: 0.22).cgColor,
                                   NSColor(red: 0.8, green: 1, blue: 0.3, alpha: 0).cgColor] as CFArray,
                          locations: [0, 1])!
    cg.drawRadialGradient(glow, startCenter: CGPoint(x: tile.midX, y: tile.midY - tile.height * 0.08), startRadius: 0,
                          endCenter: CGPoint(x: tile.midX, y: tile.midY - tile.height * 0.08), endRadius: tile.width * 0.5, options: [])
    cg.restoreGState()

    // Hairline highlight.
    cg.addPath(CGPath(roundedRect: tile.insetBy(dx: s * 0.002, dy: s * 0.002), cornerWidth: radius, cornerHeight: radius, transform: nil))
    cg.setStrokeColor(NSColor.white.withAlphaComponent(0.12).cgColor)
    cg.setLineWidth(max(1, s * 0.004))
    cg.strokePath()

    // Arrow
    let aw = tile.width * 0.40, ah = tile.width * 0.50
    let arect = CGRect(x: tile.midX - aw / 2, y: tile.midY - ah / 2, width: aw, height: ah)
    cg.addPath(arrowPath(in: arect))
    cg.setFillColor(NSColor(red: 0.80, green: 1.0, blue: 0.30, alpha: 1).cgColor)
    cg.fillPath()

    // Baseline the arrow lands on.
    let lineW = tile.width * 0.46, lineH = max(2, tile.width * 0.035)
    let line = CGRect(x: tile.midX - lineW / 2, y: arect.minY - tile.height * 0.085, width: lineW, height: lineH)
    cg.addPath(CGPath(roundedRect: line, cornerWidth: lineH / 2, cornerHeight: lineH / 2, transform: nil))
    cg.setFillColor(NSColor.white.withAlphaComponent(0.9).cgColor)
    cg.fillPath()

    NSGraphicsContext.current = nil
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
print("wrote \(out)")
