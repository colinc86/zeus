// Temporary installer background. D17 owns the final art; output stays in build/.
import AppKit

let args = CommandLine.arguments
guard args.count == 4, let width = Int(args[2]), let height = Int(args[3]), width > 0, height > 0 else {
    fatalError("Usage: placeholder.swift OUTPUT_DIRECTORY WIDTH HEIGHT")
}
let directory = URL(fileURLWithPath: args[1], isDirectory: true)
for scale in [1, 2] {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width * scale, pixelsHigh: height * scale,
                                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Cannot create placeholder") }
    bitmap.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    NSColor(srgbRed: 0.12, green: 0.11, blue: 0.18, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    let gold = NSColor(srgbRed: 1, green: 0.82, blue: 0.35, alpha: 1)
    let title: NSString = "Drag Zeus to Applications"
    let style: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 22, weight: .semibold), .foregroundColor: gold]
    let size = title.size(withAttributes: style)
    title.draw(at: NSPoint(x: (CGFloat(width) - size.width) / 2, y: CGFloat(height) - 70), withAttributes: style)
    let footer: NSString = "Installer art preview — D17 artwork pending"
    let footStyle: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.white]
    footer.draw(at: NSPoint(x: (CGFloat(width) - footer.size(withAttributes: footStyle).width) / 2, y: 35), withAttributes: footStyle)
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot encode placeholder") }
    try png.write(to: directory.appendingPathComponent(scale == 1 ? "background.png" : "background@2x.png"))
}
