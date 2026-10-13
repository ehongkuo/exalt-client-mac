// Builds the Exalt Client Mac icon from DECA's launcher icon: the red lettering becomes yellow.
// Only bright, saturated reds move (hue shifted to yellow); dark outlines and shading are kept.
// Usage: recolor-icon INPUT.iconset OUTPUT.iconset   then: iconutil -c icns OUTPUT.iconset
import AppKit

let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func rgbToHsv(_ r: Double, _ g: Double, _ b: Double) -> (h: Double, s: Double, v: Double) {
    let maxC = max(r, g, b), minC = min(r, g, b), d = maxC - minC
    var h = 0.0
    if d > 0 {
        if maxC == r { h = 60 * ((g - b) / d).truncatingRemainder(dividingBy: 6) }
        else if maxC == g { h = 60 * ((b - r) / d + 2) }
        else { h = 60 * ((r - g) / d + 4) }
    }
    if h < 0 { h += 360 }
    return (h, maxC == 0 ? 0 : d / maxC, maxC)
}
func hsvToRgb(_ h: Double, _ s: Double, _ v: Double) -> (Double, Double, Double) {
    let c = v * s, x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1)), m = v - c
    let (r, g, b): (Double, Double, Double) = h < 60 ? (c, x, 0) : h < 120 ? (x, c, 0) : h < 180 ? (0, c, x) : h < 240 ? (0, x, c) : h < 300 ? (x, 0, c) : (c, 0, x)
    return (r + m, g + m, b + m)
}

for file in try! FileManager.default.contentsOfDirectory(atPath: input.path) where file.hasSuffix(".png") {
    guard let source = NSImage(contentsOf: input.appendingPathComponent(file)),
          let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
    let w = cg.width, h = cg.height
    var pixels = [UInt8](repeating: 0, count: w * h * 4)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    for i in stride(from: 0, to: pixels.count, by: 4) {
        let a = Double(pixels[i + 3]) / 255
        guard a > 0 else { continue }
        // Un-premultiply, shift, re-premultiply.
        let r = Double(pixels[i]) / 255 / a, g = Double(pixels[i + 1]) / 255 / a, b = Double(pixels[i + 2]) / 255 / a
        let hsv = rgbToHsv(min(1, r), min(1, g), min(1, b))
        let red = hsv.h >= 340 || hsv.h <= 32
        guard red && hsv.s > 0.45 && hsv.v > 0.35 else { continue }
        let (nr, ng, nb) = hsvToRgb(50, min(1, hsv.s * 0.95), min(1, hsv.v * 1.08))
        pixels[i] = UInt8(min(255, nr * a * 255)); pixels[i + 1] = UInt8(min(255, ng * a * 255)); pixels[i + 2] = UInt8(min(255, nb * a * 255))
    }
    let result = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! result.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(file))
}
