#if os(macOS)
import CoreGraphics
import Foundation
import ImageIO
import Testing

/// F11 (Q2 DES-12): the committed app icon is full-bleed pixel art that macOS 26 can mask itself.
/// Regenerate with `zeus-sprites appicon Zeus/Resources/Assets.xcassets/AppIcon.appiconset`.
struct AppIconTests {
    static let iconSet = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Zeus/Resources/Assets.xcassets/AppIcon.appiconset")

    static let files: [(name: String, px: Int, grid: Int)] = [
        ("icon_16x16.png", 16, 16), ("icon_16x16@2x.png", 32, 32), ("icon_32x32.png", 32, 32),
        ("icon_32x32@2x.png", 64, 64), ("icon_128x128.png", 128, 64), ("icon_128x128@2x.png", 256, 64),
        ("icon_256x256.png", 256, 64), ("icon_256x256@2x.png", 512, 64), ("icon_512x512.png", 512, 64),
        ("icon_512x512@2x.png", 1024, 64),
    ]

    /// RGBA bytes of a PNG, top row first.
    static func pixels(_ name: String) throws -> (width: Int, height: Int, data: [UInt8]) {
        let url = iconSet.appendingPathComponent(name)
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil), "missing \(name)")
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let (w, h) = (image.width, image.height)
        var data = [UInt8](repeating: 0, count: w * h * 4)
        data.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ctx?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return (w, h, data)
    }

    /// Every pixel opaque: no baked corners, margin or shadow, so the system masks the art instead of
    /// shrinking it onto a plate.
    @Test(arguments: files.map(\.name))
    func iconIsFullBleed(_ name: String) throws {
        let expected = try #require(Self.files.first { $0.name == name })
        let image = try Self.pixels(name)
        #expect(image.width == expected.px && image.height == expected.px)
        let translucent = stride(from: 3, to: image.data.count, by: 4).filter { image.data[$0] < 255 }.count
        #expect(translucent == 0, "\(name): \(translucent) pixels aren't opaque")
    }

    /// Crisp pixels: each size is its grid scaled by a whole factor, every block a single color.
    @Test(arguments: files.map(\.name))
    func iconIsWholePixelScaled(_ name: String) throws {
        let expected = try #require(Self.files.first { $0.name == name })
        let image = try Self.pixels(name)
        let block = expected.px / expected.grid
        var mixed = 0
        for gy in 0..<expected.grid {
            for gx in 0..<expected.grid {
                let first = ((gy * block) * image.width + gx * block) * 4
                for y in gy * block..<(gy + 1) * block {
                    for x in gx * block..<(gx + 1) * block {
                        let i = (y * image.width + x) * 4
                        if image.data[i..<i + 4] != image.data[first..<first + 4] { mixed += 1 }
                    }
                }
            }
        }
        #expect(mixed == 0, "\(name): \(mixed) pixels break the \(expected.grid)-grid")
    }

    /// The 64-grid art keeps Zeus inside the squircle's safe area: the corners the system cuts are sky.
    @Test func subjectStaysClearOfTheSystemCorners() throws {
        let image = try Self.pixels("icon_32x32@2x.png")   // the 64 grid at 1:1
        func color(_ x: Int, _ y: Int) -> [UInt8] { Array(image.data[(y * 64 + x) * 4..<(y * 64 + x) * 4 + 3]) }
        // The outline color only appears on the character, never within 10 px of a corner (radius ≈ 14 grid px).
        let outline: [UInt8] = [0x16, 0x10, 0x2A]
        for (cx, cy) in [(0, 0), (54, 0), (0, 54), (54, 54)] {
            for y in cy..<cy + 10 { for x in cx..<cx + 10 { #expect(color(x, y) != outline, "outline at (\(x), \(y))") } }
        }
    }
}
#endif
