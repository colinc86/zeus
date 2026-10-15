import AppKit
import Carbon

/// Reads only the permitted app and opaque front-window identity, never its title or contents.
@MainActor final class TypingWindowContextSource {
    private let policy: () -> TypingPolicy
    private let locked: () -> Bool
    private let browserPrivacy: (ScreenCaptureIdentity) -> BrowserWindowPrivacy
    private let watcher: ScreenWindowContextSource
    init(policy: @escaping () -> TypingPolicy, isLocked: @escaping () -> Bool,
         browserPrivacy: @escaping (ScreenCaptureIdentity) -> BrowserWindowPrivacy = { _ in .unknown }) {
        self.policy = policy; locked = isLocked; self.browserPrivacy = browserPrivacy
        // Reuse notification ownership only; never call the screen source's title-reading current().
        watcher = ScreenWindowContextSource(policy: {
            let value = policy()
            return ScreenPolicy(enabled: value.enabled, consented: value.consented, scope: .onlyChosen,
                                apps: value.apps, privateApps: value.privateApps)
        }, isLocked: isLocked, browserPrivacy: browserPrivacy)
    }
    func current() -> TypingContext? {
        let value = policy()
        guard value.enabled, value.consented, let app = NSWorkspace.shared.frontmostApplication,
              let bundle = app.bundleIdentifier else { return nil }
        var context = TypingContext(bundleID: bundle, appName: app.localizedName ?? "App", windowID: 0,
                                    processID: app.processIdentifier, isLocked: locked(), secureInput: IsSecureEventInputEnabled())
        guard !context.isLocked, !context.secureInput, value.permits(context), !ScreenObserver.sensitiveApp(bundle) else {
            context.isPrivate = true; return context
        }
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let window = ScreenWindowContextSource.frontWindow(processID: app.processIdentifier, windows: windows),
              let id = window[kCGWindowNumber as String] as? NSNumber else { return nil }
        context.windowID = id.uint32Value
        if ScreenWindowContextSource.isBrowser(bundle),
           browserPrivacy(.init(bundleID: bundle, processID: app.processIdentifier, windowID: context.windowID)) != .normal {
            context.isPrivate = true
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return nil }
        return context
    }
    func start(onChange: @escaping () -> Void) { watcher.start(onChange: onChange) }
    func stop() { watcher.stop() }
    isolated deinit { stop() }
}
