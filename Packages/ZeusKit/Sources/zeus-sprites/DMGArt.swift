import AppKit
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import ZeusDesign
import ZeusSprites

// D17: the installer window art, rendered from code so it's reproducible.
// `zeus-sprites dmg <out-dir> --app-icon <AppIcon.appiconset> [--preview <png>]`
// writes background.png (660×420), background@2x.png, ZeusVolume.icns.
// The geometry lives in DMGLayout and is mirrored in scripts/dmg/art/LAYOUT.md.

/// The installer window geometry, in points from the top-left of the window's content area.
enum DMGLayout {
    static let window = CGSize(width: 660, height: 420)
    /// One art pixel, in points (the app's ZeusTheme.pixel).
    static let pixel: CGFloat = 2
    static let iconSize: CGFloat = 128
    static let textSize: CGFloat = 12
    static let appCenter = CGPoint(x: 166, y: 200)
    static let applicationsCenter = CGPoint(x: 494, y: 200)

    /// The art canvas, in art pixels.
    static var artWidth: Int { Int(window.width / pixel) }
    static var artHeight: Int { Int(window.height / pixel) }
}

/// A tiny top-left-origin pixel canvas over a CGContext (no antialiasing).
struct ArtCanvas {
    let width: Int
    let height: Int
    let context: CGContext

    init(width: Int, height: Int) throws {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw CLIError(description: "couldn't allocate the art canvas") }
        context.setShouldAntialias(false)
        context.interpolationQuality = .none
        self.width = width
        self.height = height
        self.context = context
    }

    func rect(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ color: UInt32) {
        guard w > 0, h > 0 else { return }
        context.setFillColor(cg(color))
        context.fill(CGRect(x: x, y: height - y - h, width: w, height: h))
    }

    func dot(_ x: Int, _ y: Int, _ color: UInt32) { rect(x, y, 1, 1, color) }

    /// Draws `image` 1:1 with its top-left at (x, y).
    func draw(_ image: CGImage, x: Int, y: Int) {
        context.draw(image, in: CGRect(x: x, y: height - y - image.height, width: image.width, height: image.height))
    }

    func image() throws -> CGImage {
        guard let image = context.makeImage() else { throw CLIError(description: "couldn't finish the art") }
        return image
    }

    func cg(_ rgba: UInt32) -> CGColor {
        let hasAlpha = rgba > 0xFFFFFF
        let v = hasAlpha ? rgba : rgba << 8 | 0xFF
        return CGColor(srgbRed: CGFloat(v >> 24 & 0xFF) / 255, green: CGFloat(v >> 16 & 0xFF) / 255,
                       blue: CGFloat(v >> 8 & 0xFF) / 255, alpha: CGFloat(v & 0xFF) / 255)
    }
}

/// Deterministic pseudo-random numbers (stars), so every run draws the same sky.
struct ArtRandom {
    var state: UInt64
    mutating func next(_ bound: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 33) % UInt64(bound))
    }
}

enum DMGPalette {
    static let outline: UInt32 = 0x14102A
    /// Sky bands, top to bottom: night over Olympus, lightening toward the horizon.
    static let sky: [UInt32] = [0x16132E, 0x1B1838, 0x211F45, 0x282853, 0x2F3262, 0x373D72, 0x404982]
    static let star: UInt32 = 0xFFFBE6
    static let starDim: UInt32 = 0x8C8FC0
    /// Plinth face: relative luminance ≈ 0.18, so Finder's labels read in black (light mode, 4.6:1)
    /// and in white (dark mode, 4.6:1).
    static let plinthFace: UInt32 = 0x6E7496
    static let plinthLight: UInt32 = 0x9AA0C2
    static let plinthDark: UInt32 = 0x4C5170
    static let cloud: UInt32 = 0x7E84B4
    static let cloudLight: UInt32 = 0xA6ABD6
    static let cloudDark: UInt32 = 0x5A5F8E
    static let bolt: UInt32 = 0xF6C544
    static let boltLight: UInt32 = 0xFFFBE6
    static let boltDark: UInt32 = 0xC4861C
}

/// Builds the background art at 1 art pixel per 2 pt.
func dmgArt(zeus: SpriteCharacter) throws -> CGImage {
    let w = DMGLayout.artWidth, h = DMGLayout.artHeight
    let c = try ArtCanvas(width: w, height: h)

    // Sky: banded, with a checkerboard dither row pair at each band boundary.
    let bands = DMGPalette.sky
    let bandHeight = h / bands.count + 1
    for y in 0..<h {
        let b = min(bands.count - 1, y / bandHeight)
        let next = min(bands.count - 1, b + 1)
        let into = y - b * bandHeight
        if into >= bandHeight - 2 && next != b {
            for x in 0..<w { c.dot(x, y, (x + y) % 2 == 0 ? bands[next] : bands[b]) }
        } else {
            c.rect(0, y, w, 1, bands[b])
        }
    }

    // Stars, away from the title and the plinths.
    var rng = ArtRandom(state: 0x5EED_2E05)
    for _ in 0..<70 {
        let x = rng.next(w), y = rng.next(150)
        let inTitle = y >= 10 && y <= 32 && x >= 50 && x <= w - 50
        let slots: [CGPoint] = [DMGLayout.appCenter, DMGLayout.applicationsCenter]
        let nearSlot = slots.contains { (slot: CGPoint) -> Bool in
            let dx: CGFloat = abs(CGFloat(x) - slot.x / 2)
            let top: CGFloat = slot.y / 2 - 40
            return dx < 42 && CGFloat(y) > top
        }
        if inTitle || nearSlot { continue }
        if rng.next(9) == 0 {
            c.dot(x, y, DMGPalette.star)
            c.dot(x - 1, y, DMGPalette.starDim); c.dot(x + 1, y, DMGPalette.starDim)
            c.dot(x, y - 1, DMGPalette.starDim); c.dot(x, y + 1, DMGPalette.starDim)
        } else {
            c.dot(x, y, rng.next(3) == 0 ? DMGPalette.star : DMGPalette.starDim)
        }
    }

    // A low cloud bank along the bottom edge.
    drawCloudBank(c, top: h - 14)

    // Plinths under both slots.
    for center in [DMGLayout.appCenter, DMGLayout.applicationsCenter] {
        drawPlinth(c, centerX: Int(center.x / DMGLayout.pixel), top: Int(center.y / DMGLayout.pixel) + 26)
    }

    // The lightning-bolt arrow between the slots.
    drawBoltArrow(c, from: Int(DMGLayout.appCenter.x / 2) + 40, to: Int(DMGLayout.applicationsCenter.x / 2) - 40,
                  y: Int(DMGLayout.appCenter.y / 2) + 2)

    // Zeus on his cloud between the plinths, waving, with the bolt arcing over his head.
    // His cloud's bottom (the sprite anchor) lands level with the plinth bases.
    let sprite = SpriteRenderer.render(zeus, state: .happy, time: 0, options: RenderOptions(showEmote: false, reduceMotion: true))
    let groundY = Int(DMGLayout.appCenter.y / DMGLayout.pixel) + 26 + 5 + 18 + 5
    c.draw(sprite, x: w / 2 - zeus.anchor.x, y: groundY - zeus.anchor.y - 1)

    return try c.image()
}

private func drawCloudBank(_ c: ArtCanvas, top: Int) {
    // Overlapping pixel lumps (half-discs) with a light rim on top and an outline.
    var lumps: [(x: Int, r: Int)] = []
    var x = -6
    var rng = ArtRandom(state: 0xC10D)
    while x < c.width + 10 {
        let r = 6 + rng.next(6)
        lumps.append((x, r))
        x += r + 3 + rng.next(4)
    }
    func inside(_ px: Int, _ py: Int) -> Bool {
        if py >= top + 8 { return true }
        return lumps.contains { l in
            let dx = px - l.x, dy = py - (top + 8)
            return dx * dx + dy * dy <= l.r * l.r && py <= top + 8
        }
    }
    for py in (top - 6)..<c.height {
        for px in 0..<c.width where inside(px, py) {
            let edge = !inside(px, py - 1)
            let nearEdge = !inside(px, py - 2)
            let color = edge ? DMGPalette.outline : nearEdge ? DMGPalette.cloudLight
                : (py > c.height - 4 && (px + py) % 2 == 0) ? DMGPalette.cloudDark : DMGPalette.cloud
            c.dot(px, py, color)
        }
    }
}

/// A Greek plinth: capital slab, face (where Finder draws the label), base slab.
private func drawPlinth(_ c: ArtCanvas, centerX: Int, top: Int) {
    let face = 60, slab = 70
    let o = DMGPalette.outline
    // Capital: outline, light top, face colour.
    c.rect(centerX - slab / 2, top, slab, 5, o)
    c.rect(centerX - slab / 2 + 1, top + 1, slab - 2, 1, DMGPalette.plinthLight)
    c.rect(centerX - slab / 2 + 1, top + 2, slab - 2, 2, DMGPalette.plinthFace)
    // Face.
    let faceTop = top + 5, faceHeight = 18
    c.rect(centerX - face / 2, faceTop, face, faceHeight, o)
    c.rect(centerX - face / 2 + 1, faceTop, face - 2, faceHeight, DMGPalette.plinthFace)
    c.rect(centerX - face / 2 + 1, faceTop, face - 2, 1, DMGPalette.plinthDark)   // shadow under the capital
    // Flutes at the outer edges only, so the label area stays plain.
    for dx in [3, 6, face - 7, face - 4] {
        c.rect(centerX - face / 2 + dx, faceTop + 2, 1, faceHeight - 3, DMGPalette.plinthDark)
    }
    // Base.
    let baseTop = faceTop + faceHeight
    c.rect(centerX - slab / 2, baseTop, slab, 5, o)
    c.rect(centerX - slab / 2 + 1, baseTop + 1, slab - 2, 1, DMGPalette.plinthLight)
    c.rect(centerX - slab / 2 + 1, baseTop + 2, slab - 2, 2, DMGPalette.plinthDark)
}

/// A zig-zag lightning bolt ending in an arrowhead, 3 px thick with an outline.
private func drawBoltArrow(_ c: ArtCanvas, from x0: Int, to x1: Int, y: Int) {
    let span = x1 - x0
    let points = [
        (x0, y - 3), (x0 + span * 3 / 10, y - 3), (x0 + span * 4 / 10, y + 4),
        (x0 + span * 6 / 10, y - 4), (x0 + span * 7 / 10, y + 3), (x1 - 8, y + 3),
    ]
    func stroke(_ size: Int, _ color: UInt32, dy: Int = 0) {
        for (a, b) in zip(points, points.dropFirst()) {
            line(a.0, a.1 + dy, b.0, b.1 + dy) { px, py in c.rect(px - size / 2, py - size / 2, size, size, color) }
        }
    }
    stroke(5, DMGPalette.outline)
    stroke(3, DMGPalette.bolt)
    stroke(1, DMGPalette.boltDark, dy: 1)
    stroke(1, DMGPalette.boltLight, dy: -1)
    // Arrowhead, pointing right, centred on the last segment.
    let tipX = x1, tipY = y + 3
    for i in 0...8 {
        let half = 8 - i
        c.rect(tipX - 9 + i, tipY - half - 1, 1, half * 2 + 3, DMGPalette.outline)
    }
    for i in 0...6 {
        let half = 6 - i
        c.rect(tipX - 8 + i, tipY - half, 1, half * 2 + 1, i < 2 ? DMGPalette.boltDark : DMGPalette.bolt)
    }
    c.rect(tipX - 6, tipY - 4, 1, 3, DMGPalette.boltLight)
}

/// Bresenham.
private func line(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, plot: (Int, Int) -> Void) {
    var x = x0, y = y0
    let dx = abs(x1 - x0), dy = -abs(y1 - y0)
    let sx = x0 < x1 ? 1 : -1, sy = y0 < y1 ? 1 : -1
    var err = dx + dy
    while true {
        plot(x, y)
        if x == x1 && y == y1 { break }
        let e2 = 2 * err
        if e2 >= dy { err += dy; x += sx }
        if e2 <= dx { err += dx; y += sy }
    }
}

/// The full background: art upscaled with nearest-neighbour, plus Departure Mono text.
struct DMGBackground: View {
    let art: CGImage

    var body: some View {
        ZStack(alignment: .top) {
            Image(decorative: art, scale: 1).resizable().interpolation(.none)
                .frame(width: DMGLayout.window.width, height: DMGLayout.window.height)
            shadowed("Drag Zeus to Applications", size: 22, color: Color(hex: 0xF6C544))
                .padding(.top, 20)
            DMGFooter().padding(.top, 360)
        }
        .frame(width: DMGLayout.window.width, height: DMGLayout.window.height)
    }

    /// Text with a hard 2 pt pixel shadow down-right, Zeus title style.
    private func shadowed(_ text: String, size: CGFloat, color: Color) -> some View {
        dmgShadowed(Text(text).font(.custom(ZeusFonts.pixelFamily, fixedSize: size)), color: color)
    }
}

/// `content` in `color` over a hard 2 pt pixel shadow down-right.
private func dmgShadowed(_ content: some View, color: Color) -> some View {
    ZStack {
        content.foregroundStyle(Color(hex: 0x14102A)).offset(x: 2, y: 2)
        content.foregroundStyle(color)
    }
    .fixedSize()
}

/// Q2 DES-20: Zeus has no Dock icon or app menu, so the footer says where Settings lives, with the
/// menu-bar bolt drawn inline (the pixel font has no ⚡).
struct DMGFooter: View {
    static let text = (before: "Then open Zeus: click ", after: " in the menu bar, then Settings → Assistant.")

    var body: some View {
        let font = Font.custom(ZeusFonts.pixelFamily, fixedSize: 11)
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            dmgShadowed(Text(Self.text.before).font(font), color: Color(hex: 0xCDD1E6))
            dmgShadowed(DMGBolt().alignmentGuide(.firstTextBaseline) { $0.height - 1 }, color: Color(hex: 0xF6C544))
            dmgShadowed(Text(Self.text.after).font(font), color: Color(hex: 0xCDD1E6))
        }
    }
}

/// The menu-bar bolt (MenuBarIcon) reduced to a 7 × 9 pt pixel shape, filled with the foreground style.
struct DMGBolt: View {
    static let rows = [
        "....##.",
        "...##..",
        "..##...",
        ".#####.",
        "#####..",
        "..##...",
        ".##....",
        "##.....",
        "#......",
    ]

    var body: some View {
        SwiftUI.Canvas { context, _ in
            for (y, row) in Self.rows.enumerated() {
                for (x, ch) in row.enumerated() where ch == "#" {
                    context.fill(Path(CGRect(x: x, y: y, width: 1, height: 1)), with: .foreground)
                }
            }
        }
        .frame(width: 7, height: 9)
        .accessibilityLabel("the Zeus bolt")
    }
}

/// What the installer window looks like in Finder, with icons at the documented centres and
/// labels in both light (black) and dark (white) mode. For review only (docs/design/dmg-d17.png).
struct DMGPreview: View {
    let background: CGImage
    let appIcon: NSImage
    let folderIcon: NSImage

    var body: some View {
        HStack(spacing: 24) {
            window(dark: false)
            window(dark: true)
        }
        .padding(24)
        .background(Color(hex: 0x2A2F3D))
    }

    private func window(dark: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach([0xFF5F57, 0xFEBC2E, 0x28C840], id: \.self) { Circle().fill(Color(hex: UInt32($0))).frame(width: 12, height: 12) }
                Spacer()
                Text("Zeus").font(.system(size: 13, weight: .semibold)).foregroundStyle(dark ? .white : .black)
                Spacer()
                Color.clear.frame(width: 52)
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(dark ? Color(hex: 0x2B2B2D) : Color(hex: 0xECECEC))
            ZStack(alignment: .topLeading) {
                Image(decorative: background, scale: 2).interpolation(.none)
                slot(appIcon, "Zeus", at: DMGLayout.appCenter, dark: dark)
                slot(folderIcon, "Applications", at: DMGLayout.applicationsCenter, dark: dark)
            }
            .frame(width: DMGLayout.window.width, height: DMGLayout.window.height, alignment: .topLeading)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .bottom) {
            Text(dark ? "dark mode labels" : "light mode labels").font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color(hex: 0xCDD1E6)).offset(y: 20)
        }
    }

    private func slot(_ icon: NSImage, _ label: String, at center: CGPoint, dark: Bool) -> some View {
        let s = DMGLayout.iconSize
        return VStack(spacing: 3) {
            Image(nsImage: icon).resizable().frame(width: s, height: s)
            Text(label).font(.system(size: DMGLayout.textSize)).foregroundStyle(dark ? .white : .black)
        }
        .frame(width: 160)
        .position(x: center.x, y: center.y + 8 + DMGLayout.textSize / 2 + 1)
    }
}

// MARK: - Volume icon

/// Draws the volume badge (a little pixel drive, Zeus-gold light) over an app-icon PNG, masked as macOS shows it.
/// `size` is the pixel size; the badge is drawn on the icon's 64-unit grid, scaled.
func volumeIcon(appIcon: CGImage, size: Int) throws -> CGImage {
    let c = try ArtCanvas(width: size, height: size)
    // The app icon is full-bleed (F11); a volume icon isn't masked by the system, so apply its shape here.
    c.draw(try systemMasked(appIcon, size: size), x: 0, y: 0)
    guard size >= 32 else { return try c.image() }
    let u = size / 64 > 0 ? size / 64 : 1               // device pixels per grid unit (≥ 1)
    let scale = size >= 64 ? u : 1
    // Drive body: 22×13 grid units at the bottom-right corner.
    let bw = 22, bh = 13
    let ox = size - (bw + 3) * scale, oy = size - (bh + 2) * scale
    func r(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ color: UInt32) { c.rect(ox + x * scale, oy + y * scale, w * scale, h * scale, color) }
    r(1, 1, bw, bh, 0x00000055)                           // drop shadow
    r(0, 0, bw, bh, DMGPalette.outline)
    r(1, 1, bw - 2, bh - 2, 0xCDD1E6)
    r(1, 1, bw - 2, 2, 0xFBFAF7)
    r(1, bh - 4, bw - 2, 3, 0x9EA4C6)
    r(2, bh - 4, bw - 4, 1, 0x7D82A8)                     // seam
    r(bw - 6, 4, 3, 3, DMGPalette.outline)
    r(bw - 5, 5, 1, 1, 0xF6C544)                          // gold activity light
    r(3, 5, 9, 1, 0x9EA4C6); r(3, 7, 9, 1, 0x9EA4C6)       // grille
    return try c.image()
}

/// Writes a .icns file directly (PNG entries), so no iconutil step is needed.
func writeICNS(_ entries: [(type: String, image: CGImage)], to path: String) throws {
    var body = Data()
    for entry in entries {
        let png = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) else {
            throw CLIError(description: "couldn't encode \(entry.type)")
        }
        CGImageDestinationAddImage(dest, entry.image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CLIError(description: "couldn't encode \(entry.type)") }
        body.append(Data(entry.type.utf8))
        body.append(bigEndian(UInt32(png.length + 8)))
        body.append(png as Data)
    }
    var file = Data("icns".utf8)
    file.append(bigEndian(UInt32(body.count + 8)))
    file.append(body)
    try file.write(to: URL(fileURLWithPath: path))
}

private func bigEndian(_ v: UInt32) -> Data {
    withUnsafeBytes(of: v.bigEndian) { Data($0) }
}

/// A PNG tagged 72 dpi (@1x) or 144 dpi (@2x), so `tiffutil -cathidpicheck` pairs them as one HiDPI TIFF.
private func writePNG(_ image: CGImage, dpi: Double, to path: String) throws {
    guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw CLIError(description: "can't write \(path)") }
    CGImageDestinationAddImage(dest, image, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { throw CLIError(description: "failed writing \(path)") }
}

private func loadPNG(_ path: String) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { throw CLIError(description: "can't read \(path)") }
    return image
}

@MainActor
func dmg(_ args: ArraySlice<String>) throws -> Int32 {
    let opts = try Options(args, flags: [])
    guard let outDir = opts.positional.first, let iconSet = opts.values["app-icon"] else { throw CLIError(description: usage) }
    guard ZeusFonts.registerBundled() else { throw CLIError(description: "couldn't register the bundled pixel font") }
    let zeus = try loadCharacters(dir: opts.values["dir"], ids: ["zeus"])[0]
    try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

    let art = try dmgArt(zeus: zeus)
    var backgrounds: [Int: CGImage] = [:]
    for scale in [1, 2] {
        let renderer = ImageRenderer(content: DMGBackground(art: art))
        renderer.scale = CGFloat(scale)
        guard let image = renderer.cgImage else { throw CLIError(description: "couldn't render the background") }
        let name = scale == 1 ? "background.png" : "background@2x.png"
        try writePNG(image, dpi: 72 * Double(scale), to: "\(outDir)/\(name)")
        print("wrote \(outDir)/\(name) (\(image.width)×\(image.height))")
        backgrounds[scale] = image
    }

    // Volume icon from the app icon set, every size.
    let sizes: [(type: String, file: String, px: Int)] = [
        ("icp4", "icon_16x16.png", 16), ("icp5", "icon_32x32.png", 32), ("ic11", "icon_16x16@2x.png", 32),
        ("ic12", "icon_32x32@2x.png", 64), ("ic07", "icon_128x128.png", 128), ("ic13", "icon_128x128@2x.png", 256),
        ("ic08", "icon_256x256.png", 256), ("ic14", "icon_256x256@2x.png", 512), ("ic09", "icon_512x512.png", 512),
        ("ic10", "icon_512x512@2x.png", 1024),
    ]
    var entries: [(type: String, image: CGImage)] = []
    for size in sizes {
        entries.append((size.type, try volumeIcon(appIcon: try loadPNG("\(iconSet)/\(size.file)"), size: size.px)))
    }
    try writeICNS(entries, to: "\(outDir)/ZeusVolume.icns")
    print("wrote \(outDir)/ZeusVolume.icns (\(entries.count) sizes)")

    if let previewPath = opts.values["preview"], let bg2x = backgrounds[2] {
        let appIcon = NSImage(cgImage: try systemMasked(try loadPNG("\(iconSet)/icon_128x128@2x.png"), size: 256),
                              size: NSSize(width: 128, height: 128))
        let folder = NSWorkspace.shared.icon(forFile: "/Applications")
        folder.size = NSSize(width: 256, height: 256)
        let volume = entries.last.map { NSImage(cgImage: $0.image, size: NSSize(width: 128, height: 128)) } ?? NSImage()
        let view = VStack(alignment: .leading, spacing: 28) {
            DMGPreview(background: bg2x, appIcon: appIcon, folderIcon: folder)
            HStack(spacing: 24) {
                Image(nsImage: volume).resizable().interpolation(.none).frame(width: 128, height: 128)
                Text("Volume icon (ZeusVolume.icns)\nThe app icon with a pixel drive badge.")
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(Color(hex: 0xCDD1E6))
            }
            .padding(.leading, 24).padding(.bottom, 24)
        }
        .background(Color(hex: 0x2A2F3D))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage else { throw CLIError(description: "couldn't render the preview") }
        try writeImages([image], to: previewPath, type: .png)
        print("wrote \(previewPath) (\(image.width)×\(image.height))")
    }
    return 0
}
