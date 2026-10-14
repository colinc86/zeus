import AppKit
import ZeusDesign

/// Stores content dimensions together, independently of the window's title bar and position.
@MainActor
enum SettingsWindowSize {
    static let minimum = CGSize(width: 572, height: 572)
    static let key = "settings.windowSize"

    static func clamped(_ size: CGSize, available: CGSize? = nil) -> CGSize {
        func dimension(_ value: CGFloat, minimum: CGFloat, available: CGFloat?) -> CGFloat {
            let upper = available.flatMap { $0.isFinite && $0 > 0 ? max(minimum, $0) : nil }
            let valid = value.isFinite ? max(minimum, value) : minimum
            // Whole UI pixels keep the stepped edges sharp; no scale transform is involved.
            let bounded = min(valid, upper ?? valid)
            return max(minimum, floor(bounded / ZeusTheme.pixel) * ZeusTheme.pixel)
        }
        return CGSize(width: dimension(size.width, minimum: minimum.width, available: available?.width),
                      height: dimension(size.height, minimum: minimum.height, available: available?.height))
    }

    static func read(from defaults: UserDefaults, available: CGSize? = nil) -> CGSize {
        let saved = defaults.dictionary(forKey: key) ?? [:]
        let size = CGSize(width: (saved["width"] as? NSNumber)?.doubleValue ?? minimum.width,
                          height: (saved["height"] as? NSNumber)?.doubleValue ?? minimum.height)
        return clamped(size, available: available)
    }

    static func save(_ size: CGSize, to defaults: UserDefaults) {
        let size = clamped(size)
        defaults.set(["width": Double(size.width), "height": Double(size.height)], forKey: key)
    }

    static func restore(_ window: NSWindow, from defaults: UserDefaults, screen: NSScreen?) {
        window.styleMask.insert(.resizable)
        window.contentMinSize = minimum
        window.contentResizeIncrements = CGSize(width: ZeusTheme.pixel, height: ZeusTheme.pixel)
        let available = screen.map { window.contentRect(forFrameRect: $0.visibleFrame).size }
        window.setContentSize(read(from: defaults, available: available))
    }
}
