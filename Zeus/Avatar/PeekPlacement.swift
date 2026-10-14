import Foundation
import ZeusDesign

/// AppKit coordinates for a peek around the opaque sprite art, including the tail in each candidate.
struct PeekPlacement {
    let frame: CGRect
    let tail: ZeusDialogTail

    static func place(art: CGRect, anchorX: CGFloat, contentSize: CGSize, screen: CGRect) -> PeekPlacement {
        let bounds = screen.insetBy(dx: 8, dy: 8)
        let tailHeight = ZeusDialogTail.height
        let gap: CGFloat = 4
        let vertical = CGSize(width: min(contentSize.width, bounds.width), height: min(contentSize.height + tailHeight, bounds.height))
        let horizontal = CGSize(width: min(contentSize.width + tailHeight, bounds.width), height: min(contentSize.height, bounds.height))
        let headY = art.maxY - art.height / 4
        let x = min(max(anchorX - vertical.width / 2, bounds.minX), bounds.maxX - vertical.width)
        let above = CGRect(x: x, y: art.maxY + gap, width: vertical.width, height: vertical.height)
        let facesRight = art.midX <= bounds.midX
        let beside = CGRect(x: facesRight ? art.maxX + gap : art.minX - gap - horizontal.width,
                            y: min(max(headY - horizontal.height / 2, bounds.minY), bounds.maxY - horizontal.height), width: horizontal.width, height: horizontal.height)
        let below = CGRect(x: x, y: art.minY - gap - vertical.height, width: vertical.width, height: vertical.height)
        let candidate: CGRect
        let edge: ZeusDialogTail.Edge
        if bounds.contains(above) { candidate = above; edge = .bottom }
        else if bounds.contains(beside) { candidate = beside; edge = facesRight ? .leading : .trailing }
        else if bounds.contains(below) { candidate = below; edge = .top }
        else { candidate = above; edge = .bottom }
        let frame = CGRect(x: min(max(candidate.minX.rounded(), bounds.minX), bounds.maxX - candidate.width),
                           y: min(max(candidate.minY.rounded(), bounds.minY), bounds.maxY - candidate.height),
                           width: candidate.width, height: candidate.height)
        let rawOffset: CGFloat = switch edge {
        case .top, .bottom: anchorX - frame.minX
        case .leading, .trailing: frame.maxY - headY // SwiftUI tail offsets run from the top.
        }
        let length = edge == .leading || edge == .trailing ? frame.height : frame.width
        let offset = min(max(rawOffset.rounded(), 16), max(16, length - 16))
        return PeekPlacement(frame: frame, tail: ZeusDialogTail(edge: edge, offset: offset))
    }
}
