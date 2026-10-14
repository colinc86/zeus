import Accelerate
import CoreGraphics
import Foundation

/// A premultiplied RGBA float buffer that composites with source-over.
///
/// Storage is one flat `[Float]` (4 floats per pixel). The whole-buffer passes (compositing a layer
/// stack, converting to RGBA8) run on vDSP, so they're fast even in unoptimized Debug builds, where
/// per-pixel Swift loops dominated the old renderer (P8). Single-pixel `blend` stays scalar.
struct PixelBuffer {
    let width: Int
    let height: Int
    private(set) var data: [Float]

    /// Shared, so every image doesn't create its own color space.
    static let colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        data = [Float](repeating: 0, count: width * height * 4)
    }

    /// Pixels as SIMD vectors (tests and debugging; not used on the hot path).
    var pixels: [SIMD4<Float>] {
        (0..<(width * height)).map { SIMD4(data[$0 * 4], data[$0 * 4 + 1], data[$0 * 4 + 2], data[$0 * 4 + 3]) }
    }

    /// Blends a straight-alpha color over the pixel at (x, y); out-of-bounds writes are clipped.
    mutating func blend(_ x: Int, _ y: Int, _ color: RGBA, opacity: Float = 1) {
        guard x >= 0, y >= 0, x < width, y < height else { return }
        let a = color.a * opacity
        guard a > 0 else { return }
        let i = (y * width + x) * 4
        data.withUnsafeMutableBufferPointer { p in
            if a >= 1 {
                p[i] = color.r; p[i + 1] = color.g; p[i + 2] = color.b; p[i + 3] = 1
            } else {
                let k = 1 - a
                p[i] = color.r * a + p[i] * k
                p[i + 1] = color.g * a + p[i + 1] * k
                p[i + 2] = color.b * a + p[i + 2] * k
                p[i + 3] = a + p[i + 3] * k
            }
        }
    }

    /// Composites `source` (premultiplied, same format) over this buffer, with source pixel (sx, sy)
    /// landing at (sx + dx, sy + dy). Out-of-bounds pixels are clipped.
    /// Per channel, `d = s + d·(1 − sₐ)`: the same source-over as `blend`, one vDSP pass per row.
    mutating func composite(_ source: PixelBuffer, dx: Int, dy: Int) {
        let x0 = max(0, dx), x1 = min(width, source.width + dx)
        let y0 = max(0, dy), y1 = min(height, source.height + dy)
        guard x0 < x1, y0 < y1 else { return }
        let n = vDSP_Length(x1 - x0)
        let w = width, sw = source.width
        var keep = [Float](repeating: 0, count: x1 - x0)
        var minusOne: Float = -1, one: Float = 1
        source.data.withUnsafeBufferPointer { s in
            data.withUnsafeMutableBufferPointer { d in
                keep.withUnsafeMutableBufferPointer { k in
                    guard let sBase = s.baseAddress, let dBase = d.baseAddress, let kBase = k.baseAddress else { return }
                    for y in y0..<y1 {
                        let srcRow = sBase + ((y - dy) * sw + (x0 - dx)) * 4
                        let dstRow = dBase + (y * w + x0) * 4
                        // keep = 1 − source alpha
                        vDSP_vsmsa(srcRow + 3, 4, &minusOne, &one, kBase, 1, n)
                        // each channel: dst = dst · keep + src
                        for c in 0..<4 {
                            vDSP_vma(dstRow + c, 4, kBase, 1, srcRow + c, 4, dstRow + c, 4, n)
                        }
                    }
                }
            }
        }
    }

    /// Converts to an 8-bit premultiplied sRGB `CGImage`.
    func makeImage() -> CGImage {
        let count = width * height * 4
        var bytes = [UInt8](repeating: 0, count: count)
        var scaled = [Float](repeating: 0, count: count)
        var scale: Float = 255, low: Float = 0, high: Float = 255
        data.withUnsafeBufferPointer { src in
            scaled.withUnsafeMutableBufferPointer { tmp in
                bytes.withUnsafeMutableBufferPointer { dst in
                    guard let s = src.baseAddress, let t = tmp.baseAddress, let d = dst.baseAddress else { return }
                    let n = vDSP_Length(count)
                    vDSP_vsmul(s, 1, &scale, t, 1, n)            // 0…1 → 0…255
                    vDSP_vclip(t, 1, &low, &high, t, 1, n)        // clamp
                    vDSP_vfixru8(t, 1, d, 1, n)                   // round to nearest, to UInt8
                }
            }
        }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: Self.colorSpace, bitmapInfo: info, provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent
              )
        else {
            // Only reachable with a zero-sized canvas, which validation rejects.
            preconditionFailure("PixelBuffer: couldn't create a \(width)×\(height) CGImage")
        }
        return image
    }
}
