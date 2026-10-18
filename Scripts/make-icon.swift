// Renders the DropWheel app icon: `swift Scripts/make-icon.swift Resources/AppIcon.icns`
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
    // Squircle background with the warm gradient from the screenshots.
    let inset = rect.insetBy(dx: 100, dy: 100)
    let bg = NSBezierPath(roundedRect: inset, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 30
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    NSColor.white.setFill()
    bg.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    bg.addClip()
    NSGradient(colors: [
        NSColor(srgbRed: 1.0, green: 0.62, blue: 0.20, alpha: 1),
        NSColor(srgbRed: 0.98, green: 0.30, blue: 0.36, alpha: 1),
        NSColor(srgbRed: 0.62, green: 0.38, blue: 0.85, alpha: 1),
    ])!.draw(in: inset, angle: -60)
    NSGraphicsContext.restoreGraphicsState()

    // The wheel.
    let c = CGPoint(x: rect.midX, y: rect.midY)
    let outer: CGFloat = 300, inner: CGFloat = 112
    NSColor.white.withAlphaComponent(0.28).setFill()
    NSBezierPath(ovalIn: NSRect(x: c.x - outer - 22, y: c.y - outer - 22, width: (outer + 22) * 2, height: (outer + 22) * 2)).fill()

    let n = 8, span = 2 * CGFloat.pi / CGFloat(n)
    for i in 0..<n {
        let mid = .pi / 2 - CGFloat(i) * span
        let gap: CGFloat = 12, r: CGFloat = 18
        let ro = outer - r, ri = inner + r
        let dOut = (gap / 2 + r) / ro, dIn = (gap / 2 + r) / ri
        let deg: (CGFloat) -> CGFloat = { $0 * 180 / .pi }
        let p = NSBezierPath()
        p.appendArc(withCenter: c, radius: ro, startAngle: deg(mid + span / 2 - dOut), endAngle: deg(mid - span / 2 + dOut), clockwise: true)
        p.appendArc(withCenter: c, radius: ri, startAngle: deg(mid - span / 2 + dIn), endAngle: deg(mid + span / 2 - dIn), clockwise: false)
        p.close()
        p.lineWidth = r * 2
        p.lineJoinStyle = .round
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.saveGState()
        ctx.setAlpha(i == 2 ? 1 : 0.9)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        (i == 2 ? NSColor(srgbRed: 0.95, green: 0.22, blue: 0.16, alpha: 1) : NSColor.white).set()
        p.fill()
        p.stroke()
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }
    // Centre "file".
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: c.x - inner + 22, y: c.y - inner + 22, width: (inner - 22) * 2, height: (inner - 22) * 2)).fill()
    let doc = NSBezierPath(roundedRect: NSRect(x: c.x - 34, y: c.y - 44, width: 68, height: 88), xRadius: 10, yRadius: 10)
    NSColor(srgbRed: 0.98, green: 0.36, blue: 0.30, alpha: 1).setFill()
    doc.fill()
    return true
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try! p.run()
p.waitUntilExit()
try? FileManager.default.copyItem(at: iconset.appendingPathComponent("icon_512x512@2x.png"),
                                  to: out.deletingPathExtension().appendingPathExtension("png"))
print("Wrote \(out.path)")
