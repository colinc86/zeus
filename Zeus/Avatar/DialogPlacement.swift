import Foundation
import ZeusDesign

struct DialogPlacement {
    var frame: CGRect
    var tail: ZeusDialogTail

    /// Keeps the tail aimed at the fixed feet anchor even when horizontal screen clamping is needed.
    static func place(art: CGRect, anchor: CGPoint, size: CGSize, screen: CGRect) -> DialogPlacement {
        let margin: CGFloat = 8
        let bounds = screen.insetBy(dx: margin, dy: margin)
        let width = min(size.width, bounds.width)
        let height = min(size.height, bounds.height)
        // Above uses the silhouette; below stays four points from the fixed feet anchor.
        let above = art.maxY + 4
        let isAbove = above + height <= bounds.maxY
        let desiredY = isAbove ? above : anchor.y - 4 - height
        let x = min(max(anchor.x - width / 2, bounds.minX), bounds.maxX - width)
        let y = min(max(desiredY, bounds.minY), bounds.maxY - height)
        let frame = CGRect(x: (x / 2).rounded() * 2, y: (y / 2).rounded() * 2, width: width, height: height)
        let offset = min(max(((anchor.x - frame.minX) / 2).rounded() * 2, 16), width - 16)
        return DialogPlacement(frame: frame, tail: ZeusDialogTail(edge: isAbove ? .bottom : .top, offset: offset))
    }
}
