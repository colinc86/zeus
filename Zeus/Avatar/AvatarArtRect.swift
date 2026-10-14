import Foundation
import Observation
import ZeusSprites

/// One cached silhouette expressed in avatar-view points. Canvas headroom stays outside the art.
struct AvatarArtRect: Equatable {
    static let decorationOverlap: CGFloat = 4
    static let warningSize = CGSize(width: 18, height: 18)
    let canvasSize: CGSize
    let bottomLeft: CGRect

    init(canvas: PixelSize, pixels: CGRect?, scale: Int) {
        let scale = CGFloat(scale)
        canvasSize = CGSize(width: CGFloat(canvas.width) * scale, height: CGFloat(canvas.height) * scale)
        let pixels = pixels ?? CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height)
        bottomLeft = CGRect(x: pixels.minX * scale, y: pixels.minY * scale,
                            width: pixels.width * scale, height: pixels.height * scale)
    }
    var topLeft: CGRect {
        CGRect(x: bottomLeft.minX, y: canvasSize.height - bottomLeft.maxY,
               width: bottomLeft.width, height: bottomLeft.height)
    }
    var badgeCorner: CGPoint { CGPoint(x: topLeft.maxX + Self.decorationOverlap, y: topLeft.minY - Self.decorationOverlap) }
    var warningTopLeft: CGRect {
        CGRect(origin: CGPoint(x: topLeft.minX - Self.decorationOverlap, y: topLeft.minY - Self.decorationOverlap), size: Self.warningSize)
    }
    func screenRect(canvasOrigin: CGPoint) -> CGRect { bottomLeft.offsetBy(dx: canvasOrigin.x, dy: canvasOrigin.y) }
    func warningFrame(in bounds: CGRect, flipped: Bool) -> CGRect {
        let rect = warningTopLeft
        return CGRect(x: bounds.minX + rect.minX, y: flipped ? bounds.minY + rect.minY : bounds.maxY - rect.maxY,
                      width: rect.width, height: rect.height)
    }
}

@MainActor @Observable
final class AvatarArtLayout {
    var rect = AvatarArtRect(canvas: PixelSize(width: 96, height: 112), pixels: nil, scale: 1)
}
