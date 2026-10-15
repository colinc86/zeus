import AppKit
import ApplicationServices
import Carbon

/// Reads metadata only for the permitted front app. No Apple events, selected text, clipboard, image or permission request.
/// Browser privacy needs a positive app-supplied normal/private signal; unknown browser windows fail closed.
@MainActor final class ScreenWindowContextSource {
    private let policy: () -> ScreenPolicy
    private let locked: () -> Bool
    private let browserPrivacy: (ScreenCaptureIdentity) -> BrowserWindowPrivacy
    private var tokens: [NSObjectProtocol] = []
    private var axObserver: AXObserver?
    private var observedApp: AXUIElement?
    private var observedWindow: AXUIElement?
    private var onChange: (() -> Void)?
    init(policy: @escaping () -> ScreenPolicy, isLocked: @escaping () -> Bool,
         browserPrivacy: @escaping (ScreenCaptureIdentity) -> BrowserWindowPrivacy = { _ in .unknown }) {
        self.policy = policy; locked = isLocked; self.browserPrivacy = browserPrivacy
    }
    isolated deinit { stop() }
    func current() -> ScreenContext? {
        let policy = policy()
        guard policy.enabled, policy.consented, let app = NSWorkspace.shared.frontmostApplication,
              let bundle = app.bundleIdentifier else { return nil }
        var result = ScreenContext(bundleID: bundle, appName: app.localizedName ?? "App", windowTitle: "", windowID: 0,
                                   processID: app.processIdentifier, isLocked: locked(), secureInput: IsSecureEventInputEnabled())
        guard !result.isLocked, !result.secureInput, policy.permits(result), !ScreenObserver.sensitiveApp(bundle) else {
            result.isPrivate = true; return result
        }
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let window = Self.frontWindow(processID: app.processIdentifier, windows: windows),
              let id = window[kCGWindowNumber as String] as? NSNumber else { return nil }
        result.windowID = id.uint32Value
        if Self.isBrowser(bundle), browserPrivacy(.init(bundleID: bundle, processID: app.processIdentifier, windowID: result.windowID)) != .normal {
            result.isPrivate = true; return result
        }
        result.windowTitle = window[kCGWindowName as String] as? String ?? ""
        if AXIsProcessTrusted() {
            let application = AXUIElementCreateApplication(app.processIdentifier)
            if let focused = Self.element(application, kAXFocusedUIElementAttribute),
               Self.string(focused, kAXSubroleAttribute) == kAXSecureTextFieldSubrole { result.secureInput = true; return result }
            guard let focused = Self.element(application, kAXFocusedWindowAttribute) else { return nil }
            // Public AX has no window-number accessor. Require focused-window bounds to agree with CG's front window.
            guard let position = Self.point(focused), let size = Self.size(focused),
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  abs(position.x - rect.minX) <= 4, abs(position.y - rect.minY) <= 4,
                  abs(size.width - rect.width) <= 4, abs(size.height - rect.height) <= 4 else { return nil }
            result.windowTitle = Self.string(focused, kAXTitleAttribute) ?? result.windowTitle
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return nil }
        return result
    }
    /// Workspace and AX title/focus events drive the observer's dwell timer. No screenshot polling.
    func start(onChange: @escaping () -> Void) {
        stop(); self.onChange = onChange
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.sessionDidResignActiveNotification] {
            tokens.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.connectAX(); self?.onChange?() }
            })
        }
        connectAX()
    }
    func stop() {
        for token in tokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }; tokens = []
        disconnectAX(); onChange = nil
    }
    private func disconnectAX() {
        if let axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObserver), .commonModes)
            if let observedApp {
                AXObserverRemoveNotification(axObserver, observedApp, kAXFocusedWindowChangedNotification as CFString)
                AXObserverRemoveNotification(axObserver, observedApp, kAXFocusedUIElementChangedNotification as CFString)
            }
            if let observedWindow { AXObserverRemoveNotification(axObserver, observedWindow, kAXTitleChangedNotification as CFString) }
        }
        axObserver = nil; observedApp = nil; observedWindow = nil
    }
    private func connectAX() {
        disconnectAX()
        guard policy().enabled, policy().consented, AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
              let bundle = app.bundleIdentifier else { return }
        let candidate = ScreenContext(bundleID: bundle, appName: "", windowTitle: "", windowID: 0, processID: app.processIdentifier)
        guard !locked(), policy().permits(candidate), !ScreenObserver.sensitiveApp(bundle) else { return }
        // Watching focus/title notifications carries no captured text. current() alone authorizes a particular window.
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            // The observer is removed synchronously in stop before the owner can be released.
            let source = Unmanaged<ScreenWindowContextSource>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { source.connectAX(); source.onChange?() }
        }
        guard AXObserverCreate(app.processIdentifier, callback, &observer) == .success, let observer else { return }
        axObserver = observer; let element = AXUIElementCreateApplication(app.processIdentifier); observedApp = element
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(observer, element, kAXFocusedWindowChangedNotification as CFString, refcon)
        AXObserverAddNotification(observer, element, kAXFocusedUIElementChangedNotification as CFString, refcon)
        if let window = Self.element(element, kAXFocusedWindowAttribute) {
            observedWindow = window; AXObserverAddNotification(observer, window, kAXTitleChangedNotification as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }
    static func frontWindow(processID: Int32, windows: [[String: Any]]) -> [String: Any]? {
        windows.first { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processID &&
            ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 &&
            ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value != nil }
    }
    static func isBrowser(_ bundle: String) -> Bool {
        ["com.apple.Safari", "com.google.Chrome", "com.microsoft.edgemac", "org.mozilla.firefox", "com.brave.Browser",
         "company.thebrowser.Browser", "com.operasoftware.Opera", "com.vivaldi.Vivaldi", "com.kagi.kagimacOS"].contains { bundle.hasPrefix($0) }
    }
    private static func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?; guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }; return value
    }
    private static func element(_ source: AXUIElement, _ key: String) -> AXUIElement? {
        guard let value = attribute(source, key), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }
    private static func string(_ source: AXUIElement, _ key: String) -> String? { attribute(source, key) as? String }
    private static func point(_ source: AXUIElement) -> CGPoint? {
        guard let value = attribute(source, kAXPositionAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cgPoint, &point) ? point : nil
    }
    private static func size(_ source: AXUIElement) -> CGSize? {
        guard let value = attribute(source, kAXSizeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cgSize, &size) ? size : nil
    }
}
