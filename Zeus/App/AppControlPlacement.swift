import AppKit

struct AppControlScreen: Equatable {
    let frame: CGRect
    let visibleFrame: CGRect
    let scale: CGFloat
    var isMain = false
}

/// Shares drag clamping; only named corners/edges use the larger 24-point inset.
enum AppControlPlacement {
    static func origin(for placement: AvatarPlacement, avatar: CGRect, screens: [AppControlScreen], activeWindow: CGRect?) throws -> CGPoint {
        guard !screens.isEmpty else { throw AppControlError.invalidArgument("No display is available.") }
        if case .point(let index, let x, let y) = placement {
            guard screens.indices.contains(index), x.isFinite, y.isFinite else {
                throw AppControlError.invalidArgument("Choose a display and finite coordinates.")
            }
            let screen = screens[index]
            return PanelPlacement.clamp(CGRect(origin: CGPoint(x: screen.frame.minX + x, y: screen.frame.minY + y),
                                               size: avatar.size), to: screen.visibleFrame).origin
        }
        let target: CGRect
        if placement == .nearActiveWindow {
            target = activeWindow.flatMap { PanelPlacement.screen(for: $0, in: screens.map(\.visibleFrame)) }
                ?? screens.first(where: \.isMain)?.visibleFrame ?? screens[0].visibleFrame
        } else {
            target = PanelPlacement.screen(for: avatar, in: screens.map(\.visibleFrame)) ?? screens[0].visibleFrame
        }
        let left = target.minX + 24, right = max(left, target.maxX - 24 - avatar.width)
        let bottom = target.minY + 24, top = max(bottom, target.maxY - 24 - avatar.height)
        let point: CGPoint
        switch placement {
        case .topLeft: point = CGPoint(x: left, y: top)
        case .topRight: point = CGPoint(x: right, y: top)
        case .bottomLeft: point = CGPoint(x: left, y: bottom)
        case .bottomRight: point = CGPoint(x: right, y: bottom)
        case .nearActiveWindow:
            let window = activeWindow ?? target
            let middleX = window.midX - avatar.width / 2, middleY = window.midY - avatar.height / 2
            let edges = [(target.maxX - window.maxX, CGPoint(x: right, y: middleY)),
                         (window.minX - target.minX, CGPoint(x: left, y: middleY)),
                         (target.maxY - window.maxY, CGPoint(x: middleX, y: top)),
                         (window.minY - target.minY, CGPoint(x: middleX, y: bottom))]
            point = activeWindow == nil ? CGPoint(x: right, y: target.midY - avatar.height / 2)
                : edges.enumerated().min { max(0, $0.element.0) < max(0, $1.element.0) }?.element.1 ?? CGPoint(x: right, y: middleY)
        case .point: throw AppControlError.invalidArgument("Choose a display and coordinates.")
        }
        return PanelPlacement.clamp(CGRect(origin: point, size: avatar.size), to: target).origin
    }

    @MainActor static func frontmostWindow() -> CGRect? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]],
              let primary = NSScreen.screens.first else { return nil }
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.processIdentifier,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), rect.width > 0, rect.height > 0 else { continue }
            // CGWindowList uses a top-left origin on the primary display, unlike AppKit.
            return CGRect(x: rect.minX, y: primary.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        }
        return nil
    }
}
