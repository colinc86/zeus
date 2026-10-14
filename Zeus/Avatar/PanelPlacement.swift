import Foundation

/// Placement in AppKit's global, bottom-left screen coordinate system.
enum PanelPlacement {
    static let margin: CGFloat = 10

    /// Prefer the display containing most of the panel, or the nearest display after unplugging one.
    static func screen(for panel: CGRect, in screens: [CGRect]) -> CGRect? {
        let intersecting = screens.max { lhs, rhs in
            intersectionArea(panel, lhs) < intersectionArea(panel, rhs)
        }
        if let intersecting, intersectionArea(panel, intersecting) > 0 { return intersecting }
        return screens.min { distance(panel, $0) < distance(panel, $1) }
    }

    static func clamp(_ panel: CGRect, to screen: CGRect) -> CGRect {
        let bounds = screen.insetBy(dx: margin, dy: margin)
        let size = CGSize(width: min(panel.width, max(1, bounds.width)),
                          height: min(panel.height, max(1, bounds.height)))
        return CGRect(x: min(max(panel.minX, bounds.minX), bounds.maxX - size.width),
                      y: min(max(panel.minY, bounds.minY), bounds.maxY - size.height),
                      width: size.width, height: size.height)
    }

    static func card(near avatar: CGRect, size: CGSize, screen: CGRect) -> CGRect {
        let gap: CGFloat = 12
        let above = avatar.maxY + gap
        let y = above + size.height <= screen.maxY - margin ? above : avatar.minY - gap - size.height
        return clamp(CGRect(x: avatar.midX - size.width / 2, y: y,
                            width: size.width, height: size.height), to: screen)
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let rect = lhs.intersection(rhs)
        return rect.isNull ? 0 : rect.width * rect.height
    }

    private static func distance(_ panel: CGRect, _ screen: CGRect) -> CGFloat {
        let dx = max(screen.minX - panel.midX, 0, panel.midX - screen.maxX)
        let dy = max(screen.minY - panel.midY, 0, panel.midY - screen.maxY)
        return dx * dx + dy * dy
    }
}
