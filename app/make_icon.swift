// Fallback icon for Exalt Client Mac (a shield with an HP bar), used only if DECA's launcher icon is missing.
// Usage: swift make_icon.swift OUTPUT.iconset   then: iconutil -c icns OUTPUT.iconset
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func draw(_ size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    // Background: macOS-style rounded square, dark gradient.
    let tile = NSBezierPath(roundedRect: NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s), xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(starting: NSColor(red: 0.13, green: 0.15, blue: 0.19, alpha: 1), ending: NSColor(red: 0.05, green: 0.06, blue: 0.08, alpha: 1))!.draw(in: tile, angle: -90)
    // Shield.
    let shield = NSBezierPath()
    shield.move(to: NSPoint(x: 512 * s, y: 790 * s))
    shield.curve(to: NSPoint(x: 290 * s, y: 700 * s), controlPoint1: NSPoint(x: 430 * s, y: 760 * s), controlPoint2: NSPoint(x: 360 * s, y: 730 * s))
    shield.curve(to: NSPoint(x: 512 * s, y: 225 * s), controlPoint1: NSPoint(x: 290 * s, y: 450 * s), controlPoint2: NSPoint(x: 380 * s, y: 310 * s))
    shield.curve(to: NSPoint(x: 734 * s, y: 700 * s), controlPoint1: NSPoint(x: 644 * s, y: 310 * s), controlPoint2: NSPoint(x: 734 * s, y: 450 * s))
    shield.curve(to: NSPoint(x: 512 * s, y: 790 * s), controlPoint1: NSPoint(x: 664 * s, y: 730 * s), controlPoint2: NSPoint(x: 594 * s, y: 760 * s))
    shield.close()
    let mint = NSColor(red: 0.35, green: 0.88, blue: 0.72, alpha: 1)
    mint.withAlphaComponent(0.16).setFill(); shield.fill()
    mint.setStroke(); shield.lineWidth = 34 * s; shield.stroke()
    // HP bar inside the shield: track, then a coral-to-mint fill at 65%.
    let track = NSBezierPath(roundedRect: NSRect(x: 372 * s, y: 470 * s, width: 280 * s, height: 64 * s), xRadius: 32 * s, yRadius: 32 * s)
    NSColor.white.withAlphaComponent(0.14).setFill(); track.fill()
    let fill = NSBezierPath(roundedRect: NSRect(x: 372 * s, y: 470 * s, width: 182 * s, height: 64 * s), xRadius: 32 * s, yRadius: 32 * s)
    NSGradient(starting: NSColor(red: 0.98, green: 0.42, blue: 0.40, alpha: 1), ending: mint)!.draw(in: fill, angle: 0)
    // Plus mark above the bar.
    NSColor.white.setFill()
    NSBezierPath(roundedRect: NSRect(x: 492 * s, y: 572 * s, width: 40 * s, height: 120 * s), xRadius: 12 * s, yRadius: 12 * s).fill()
    NSBezierPath(roundedRect: NSRect(x: 452 * s, y: 612 * s, width: 120 * s, height: 40 * s), xRadius: 12 * s, yRadius: 12 * s).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let png = draw(CGFloat(base * scale)).representation(using: .png, properties: [:])!
        try! png.write(to: out.appendingPathComponent(name))
    }
}
