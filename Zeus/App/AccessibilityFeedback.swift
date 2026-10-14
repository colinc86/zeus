import AppKit

/// Announces the result of an explicit local action without moving keyboard or VoiceOver focus.
@MainActor enum AccessibilityFeedback {
    static func announce(_ message: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
}
