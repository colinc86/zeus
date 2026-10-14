import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import ZeusSprites

// F11 (Q2 DES-12): the app icon, rendered from code so it's reproducible.
// `zeus-sprites appicon <AppIcon.appiconset>` writes the ten PNGs the set's Contents.json names.
//
// The art is full-bleed: an opaque square with no frame, corners or shadow. macOS 26 masks it to the
// system squircle and adds the edge itself. Art with transparent margins or its own frame gets shrunk onto a
// grey plate instead. Three hand-tuned grids: 64 (scaled ×2…×16 for 128–1024 px), 32 (32 px and 16@2x), and
// 16. The grids keep the subject inside the squircle's safe area, so the system's corner mask cuts only sky.

enum AppIconArt {
    /// The night sky, top to bottom; the bands get an ordered dither where they meet.
    static let skyTop: (Int, Int, Int) = (38, 40, 98)
    static let skyBottom: (Int, Int, Int) = (92, 128, 214)
    static let star: UInt32 = 0xFFFBE6
    static let spark: UInt32 = 0x8FE3FF
    /// The low cloud bank: lighter than the sky, darker than Zeus's own cloud, so his cloud stays the brightest.
    static let bank: UInt32 = 0x7F95D8
    static let bankRim: UInt32 = 0xA9B8EC
    /// The bank's outline: a dark sky blue, not the character outline, so it sits behind him.
    static let bankEdge: UInt32 = 0x34418A

    /// Palette for the hand grids (`.` is transparent).
    static let palette: [Character: UInt32] = [
        "k": 0x16102A, "w": 0xFBFAF7, "g": 0xBEC4DE, "L": 0x3F8A35, "l": 0x86C95A,
        "s": 0xF6C9A4, "S": 0xDC9A7C, "e": 0x2A2140, "p": 0xF4A3A0, "m": 0x8E3B46,
        "o": 0xFFE14A, "O": 0xFF9E1A, "h": 0xFFFBE6, "c": 0xFFFFFF, "C": 0xD2DFF3,
    ]

    /// Fills the whole canvas with the banded sky (full-bleed: the system mask supplies the shape).
    static func sky(_ c: ArtCanvas, bands: Int) {
        let n = c.height
        for y in 0..<n {
            let t = Double(y) / Double(max(1, n - 1))
            let band = min(bands - 1, Int(t * Double(bands)))
            let frac = t * Double(bands) - Double(band)
            for x in 0..<c.width {
                let b = frac > 0.75 && (x + y) % 2 == 0 && band < bands - 1 ? band + 1 : band
                c.dot(x, y, mix(Double(b) / Double(bands - 1)))
            }
        }
    }

    static func mix(_ t: Double) -> UInt32 {
        func ch(_ a: Int, _ b: Int) -> UInt32 { UInt32(Double(a) + Double(b - a) * t) }
        return ch(skyTop.0, skyBottom.0) << 16 | ch(skyTop.1, skyBottom.1) << 8 | ch(skyTop.2, skyBottom.2)
    }

    static func blit(_ c: ArtCanvas, _ rows: [String], _ x0: Int, _ y0: Int) {
        for (j, row) in rows.enumerated() {
            for (i, ch) in row.enumerated() where ch != "." {
                if let color = palette[ch] { c.dot(x0 + i, y0 + j, color) }
            }
        }
    }

    /// Low rounded lumps along the bottom edge, with a light rim and an outline on top.
    static func cloudBank(_ c: ArtCanvas, top: Int, lumps: [(x: Int, r: Int)]) {
        func inside(_ x: Int, _ y: Int) -> Bool {
            if y >= c.height { return false }
            if y >= top + 4 { return true }
            return lumps.contains { lump in
                let dx = Double(x - lump.x) + 0.5, dy = Double(y - (top + lump.r)) + 0.5
                return dx * dx + dy * dy <= Double(lump.r * lump.r)
            }
        }
        for y in max(0, top - 8)..<c.height {
            for x in 0..<c.width where inside(x, y) {
                if !inside(x, y - 1) { c.dot(x, y, bankEdge) }
                else if !inside(x, y - 2) { c.dot(x, y, bankRim) }
                else { c.dot(x, y, bank) }
            }
        }
    }

    /// 64 × 64: Zeus on his cloud, bolt raised, over a starry sky and a cloud bank.
    static func grid64(zeus: SpriteCharacter) throws -> CGImage {
        let c = try ArtCanvas(width: 64, height: 64)
        sky(c, bands: 6)
        for (x, y) in [(52, 10), (39, 8), (51, 17), (55, 13), (9, 11), (15, 19), (6, 29), (57, 33), (21, 7), (31, 5), (59, 24)] {
            c.dot(x, y, star)
        }
        for (x, y) in [(40, 13), (4, 41)] { c.dot(x, y, spark) }
        cloudBank(c, top: 55, lumps: [(2, 4), (11, 5), (21, 4), (32, 5), (43, 4), (53, 5), (62, 4)])
        // The working pose (bolt raised), still: the same art the avatar shows, at 1 art px per grid unit.
        let sprite = SpriteRenderer.render(zeus, state: .working, time: 0, options: RenderOptions(showEmote: false, reduceMotion: true))
        let box = opaqueBounds(sprite)
        c.draw(sprite, x: 32 - (box.minX + box.maxX + 1) / 2, y: 53 - box.maxY)
        return try c.image()
    }

    /// 32 × 32: a bust (head, beard, laurel) on a cloud, bolt at the upper right.
    static func grid32() throws -> CGImage {
        let c = try ArtCanvas(width: 32, height: 32)
        sky(c, bands: 4)
        blit(c, [
            "....kk....kkk......",
            "...kcck..kccck.kk..",
            "..kcccckkccccckcck.",
            ".kccccccccccccccck.",
            "kccccccccccccccccck",
            "kCCcCCCcCCCcCCCcCCk",
            ".kkkkkkkkkkkkkkkkk.",
        ], 6, 22)
        blit(c, [
            "....kkkkkkkk....",
            "..kkwwwwwwwwkk..",
            ".kwwwwwwwwwwwwk.",
            "kwlLlLlLlLlLlLwk",
            "kwwssssssssssswk",
            "kwwswwsssswwswwk",
            "kwwsesssssseswwk",
            "kwpssssSSsssspwk",
            "kwwwwwwwwwwwwwwk",
            "kwwwwwgmmgwwwwwk",
            "kwgwwwwwwwwwwgwk",
            ".kwwgwwwwwwgwwk.",
            "..kwwwgwwgwwwk..",
            "...kwwwwwwwwk...",
            "....kkwwwwkk....",
            "......kkkk......",
        ], 7, 7)
        blit(c, [
            "...kk.",
            "..khok",
            ".khok.",
            "khoook",
            ".koOk.",
            ".kOk..",
            "kOk...",
            ".k....",
        ], 21, 3)
        for (x, y) in [(27, 6), (19, 5), (4, 8), (28, 15)] { c.dot(x, y, star) }
        return try c.image()
    }

    /// 16 × 16: the face, the bolt, a cloud. Every pixel counts; outlines only where they separate shapes.
    static func grid16() throws -> CGImage {
        let c = try ArtCanvas(width: 16, height: 16)
        sky(c, bands: 3)
        blit(c, [
            "..kkkkkk..",
            ".kllllLLk.",
            "kwsssssswk",
            "kseSssSesk",
            "kwssmmsswk",
            "kwwwwwwwwk",
            ".kwwwwwwk.",
            "..kwwwwk..",
            "...kkkk...",
        ], 3, 3)
        blit(c, ["..kk", ".kok", "kook", ".ok.", "kk.."], 11, 1)
        blit(c, [".cc.cc.", "ccccccc", "CCCCCCC"], 4, 12)
        return try c.image()
    }

    /// The bounding box of `image`'s opaque pixels, top-left origin.
    static func opaqueBounds(_ image: CGImage) -> (minX: Int, minY: Int, maxX: Int, maxY: Int) {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        data.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var box = (minX: w, minY: h, maxX: -1, maxY: -1)
        for y in 0..<h {
            for x in 0..<w where data[(y * w + x) * 4 + 3] > 0 {
                box = (min(box.minX, x), min(box.minY, y), max(box.maxX, x), max(box.maxY, y))
            }
        }
        return box
    }

    /// Every file in the icon set: (file name, source grid, scale factor).
    static func files(zeus: SpriteCharacter) throws -> [(name: String, image: CGImage)] {
        let g64 = try grid64(zeus: zeus), g32 = try grid32(), g16 = try grid16()
        let plan: [(String, CGImage, Int)] = [
            ("icon_16x16.png", g16, 1), ("icon_16x16@2x.png", g32, 1), ("icon_32x32.png", g32, 1),
            ("icon_32x32@2x.png", g64, 1), ("icon_128x128.png", g64, 2), ("icon_128x128@2x.png", g64, 4),
            ("icon_256x256.png", g64, 4), ("icon_256x256@2x.png", g64, 8), ("icon_512x512.png", g64, 8),
            ("icon_512x512@2x.png", g64, 16),
        ]
        return try plan.map { name, grid, scale in (name, try upscale(grid, by: scale)) }
    }

    /// Nearest-neighbour upscale by a whole factor.
    static func upscale(_ image: CGImage, by factor: Int) throws -> CGImage {
        guard factor > 1 else { return image }
        let c = try ArtCanvas(width: image.width * factor, height: image.height * factor)
        c.context.interpolationQuality = .none
        c.context.draw(image, in: CGRect(x: 0, y: 0, width: c.width, height: c.height))
        return try c.image()
    }
}

/// The icon as macOS 26 shows a full-bleed icon: inset to the 824/1024 grid and masked to a continuous
/// rounded square. For previews (the DMG preview, the volume icon), not for the icon set itself.
func systemMasked(_ art: CGImage, size: Int) throws -> CGImage {
    let c = try ArtCanvas(width: size, height: size)
    let inset = CGFloat(size) * 100 / 1024
    let rect = CGRect(x: inset, y: inset, width: CGFloat(size) - 2 * inset, height: CGFloat(size) - 2 * inset)
    c.context.setShouldAntialias(true)
    c.context.addPath(RoundedRectangle(cornerRadius: rect.width * 0.225, style: .continuous).path(in: rect).cgPath)
    c.context.clip()
    c.context.interpolationQuality = size >= art.width ? .none : .high
    c.context.draw(art, in: rect)
    return try c.image()
}

func appicon(_ args: ArraySlice<String>) throws -> Int32 {
    let opts = try Options(args, flags: [])
    guard let iconSet = opts.positional.first else { throw CLIError(description: usage) }
    let zeus = try loadCharacters(dir: opts.values["dir"], ids: ["zeus"])[0]
    for file in try AppIconArt.files(zeus: zeus) {
        let path = "\(iconSet)/\(file.name)"
        guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw CLIError(description: "can't write \(path)") }
        CGImageDestinationAddImage(dest, file.image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CLIError(description: "failed writing \(path)") }
        print("wrote \(path) (\(file.image.width)×\(file.image.height))")
    }
    return 0
}
