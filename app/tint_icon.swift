// Tints an iconset blue in place, so a staging build (./build.sh --stage) is told apart from the
// installed app in the Dock and Finder. Usage: tint-icon ICONSET
import AppKit

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
for file in try! FileManager.default.contentsOfDirectory(atPath: folder.path) where file.hasSuffix(".png") {
    let url = folder.appendingPathComponent(file)
    guard let cg = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
    let rect = CGRect(x: 0, y: 0, width: cg.width, height: cg.height)
    let ctx = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(cg, in: rect)
    ctx.setBlendMode(.sourceAtop)   // only where the icon is drawn, keeping its shape
    ctx.setFillColor(NSColor.systemBlue.withAlphaComponent(0.5).cgColor)
    ctx.fill(rect)
    try! NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!.write(to: url)
}
