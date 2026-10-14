import Foundation
import CoreGraphics
import ZeusSprites

/// Converts top-left pixel anchors to bottom-left AppKit window coordinates.
enum SpriteLayout {
    static func offset(canvas: PixelSize, anchor: PixelPoint, scale: Int) -> CGPoint {
        CGPoint(x: anchor.x * scale, y: (canvas.height - anchor.y) * scale)
    }

    static func frame(at anchorOnScreen: CGPoint, canvas: PixelSize, anchor: PixelPoint, scale: Int) -> CGRect {
        let offset = offset(canvas: canvas, anchor: anchor, scale: scale)
        return CGRect(x: anchorOnScreen.x - offset.x, y: anchorOnScreen.y - offset.y,
                      width: CGFloat(canvas.width * scale), height: CGFloat(canvas.height * scale))
    }
    /// The stable idle silhouette excludes transparent emote headroom and procedural motion.
    static func artBounds(character: SpriteCharacter) -> CGRect? {
        let image = SpriteRenderer.render(character, state: .idle, time: 0, options: .init(showEmote: false, reduceMotion: true))
        guard let data = image.dataProvider?.data else { return nil }
        let bytes = [UInt8](data as Data)
        var left = image.width, top = image.height, right = -1, bottom = -1
        for y in 0..<image.height {
            for x in 0..<image.width {
                let alpha = y * image.bytesPerRow + x * 4 + 3
                guard alpha < bytes.count, bytes[alpha] > 0 else { continue }
                left = min(left, x); right = max(right, x)
                top = min(top, y); bottom = max(bottom, y)
            }
        }
        guard right >= left, bottom >= top else { return nil }
        return CGRect(x: left, y: image.height - bottom - 1, width: right - left + 1, height: bottom - top + 1)
    }
}

