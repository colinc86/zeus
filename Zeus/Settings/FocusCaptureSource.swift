import AppKit
import ApplicationServices
import Carbon

/// Raw values exist only while a capture is being redacted. They are never logged, cached or persisted.
struct FocusRecord: Equatable, Sendable {
    var title: String
    var document: String?
    var address: String?
    var subject: String?
    var text: String {
        [("Window", Optional(title)), ("Document", document), ("URL", address), ("Subject", subject)]
            .compactMap { label, value in value.flatMap { $0.isEmpty ? nil : "\(label): \($0)" } }.joined(separator: "\n")
    }
}
struct FocusApplication: Equatable, Sendable { var pid: pid_t; var bundleID: String; var name: String }

@MainActor protocol FocusCaptureSource: AnyObject {
    var isTrusted: Bool { get }
    var isSecure: Bool { get }
    var isLocked: Bool { get }
    var application: FocusApplication? { get }
    /// Must return nil for a private or unclassifiable browser window, before reading its title or address.
    func capture(_ application: FocusApplication) async throws -> FocusRecord?
}

/// A deliberately narrow AX reader: window title + AXDocument, never field values or a web page's contents.
@MainActor final class MacFocusCaptureSource: FocusCaptureSource {
    private(set) var isLocked = false
    private var tokens: [NSObjectProtocol] = []
    init() {
        // CGSession's state covers launch while already locked. Notifications cover the running lifecycle.
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any] {
            isLocked = session["CGSSessionScreenIsLocked"] as? Bool ?? false
        }
        let center = DistributedNotificationCenter.default()
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            tokens.append(center.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isLocked = locked }
            })
        }
    }
    isolated deinit { for token in tokens { DistributedNotificationCenter.default().removeObserver(token) } }
    var isTrusted: Bool { AXIsProcessTrusted() }
    var isSecure: Bool { IsSecureEventInputEnabled() }
    var application: FocusApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication, let id = app.bundleIdentifier else { return nil }
        return .init(pid: app.processIdentifier, bundleID: id, name: app.localizedName ?? id)
    }

    func capture(_ application: FocusApplication) async throws -> FocusRecord? {
        guard isTrusted, !isSecure, !isLocked, self.application == application else { return nil }
        // Safari has no documented normal/private window signal. Never infer public from an absent indicator.
        if application.bundleID == "com.apple.Safari" { return FocusRecord(title: "Details not kept") }
        if ["com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary", "com.google.Chrome.dev", "com.microsoft.edgemac"].contains(application.bundleID) {
            // Bind one window object, test its mode, then read that same object's tab. An app switch or a newly
            // focused incognito window cannot make a second front-window lookup leak its title or URL.
            let script = """
            tell application id "\(application.bundleID)"
                set w to front window
                if mode of w is not "normal" then return missing value
                set t to active tab of w
                return {title of t, URL of t}
            end tell
            """
            guard let values = await Self.script(script), values.count == 2,
                  !isSecure, !isLocked, self.application == application else { return nil }
            return FocusRecord(title: values[0], address: values[1])
        }
        let app = AXUIElementCreateApplication(application.pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let window = Self.element(app, kAXFocusedWindowAttribute) else { return nil }
        let title = Self.attribute(window, kAXTitleAttribute) as? String ?? ""
        var record = FocusRecord(title: title, document: Self.attribute(window, kAXDocumentAttribute) as? String)
        if application.bundleID == "com.apple.mail" {
            record.subject = await Self.script("tell application id \"com.apple.mail\"\nif (count of selection) is 1 then return {subject of item 1 of selection}\nend tell")?.first
        }
        guard !isSecure, !isLocked, self.application == application else { return nil }
        return record.text.isEmpty ? nil : record
    }

    nonisolated private static func script(_ source: String) async -> [String]? {
        await Task.detached(priority: .utility) {
            var error: NSDictionary?
            let result = NSAppleScript(source: "with timeout of 2 seconds\n\(source)\nend timeout")?.executeAndReturnError(&error)
            guard error == nil, let result, result.numberOfItems > 0 else { return nil }
            var values: [String] = []
            for index in 1...result.numberOfItems {
                guard let value = result.atIndex(index)?.stringValue else { return nil }
                values.append(value)
            }
            return values
        }.value
    }
    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    private static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }
}
