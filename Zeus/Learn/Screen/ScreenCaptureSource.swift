import AppKit
import Carbon
import ScreenCaptureKit

@MainActor protocol ScreenCapturing: AnyObject {
    var hasPermission: Bool { get }
    func requestPermission() -> Bool
    func capture(_ context: ScreenContext) async throws -> CapturedScreenFrame
}
extension ScreenCapturing { func requestPermission() -> Bool { hasPermission } }
/// Only a desktop-independent single-window filter is used, never a display or rectangle capture.
@MainActor final class WindowScreenCapture: ScreenCapturing {
    var hasPermission: Bool { CGPreflightScreenCaptureAccess() }
    func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }
    private static func isFront(_ context: ScreenContext) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == context.processID,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let front = windows.first(where: { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == context.processID && ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 }) else { return false }
        return (front[kCGWindowNumber as String] as? NSNumber)?.uint32Value == context.windowID
    }
    func capture(_ context: ScreenContext) async throws -> CapturedScreenFrame {
        guard hasPermission, !IsSecureEventInputEnabled(),
              Self.isFront(context) else { throw ScreenCaptureError.unavailable }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard !IsSecureEventInputEnabled(), Self.isFront(context),
              let window = content.windows.first(where: { $0.windowID == context.windowID && $0.owningApplication?.processID == context.processID }),
              window.windowLayer == 0, window.isOnScreen, window.frame.width > 0, window.frame.height > 0 else { throw ScreenCaptureError.unavailable }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = min(1, 1280 / max(window.frame.width, window.frame.height))
        config.width = max(1, Int(window.frame.width * scale)); config.height = max(1, Int(window.frame.height * scale))
        config.showsCursor = false; config.captureResolution = .nominal
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return CapturedScreenFrame(image: image)
    }
}
