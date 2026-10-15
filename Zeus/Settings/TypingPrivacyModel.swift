import Foundation
import Observation

enum TypingPermissionPresentation: Equatable {
    case notRequested, waiting, granted, reopenRequired, denied, revoked
    var caption: String? {
        switch self {
        case .notRequested, .granted: nil
        case .waiting: "Waiting for Input Monitoring permission."
        case .reopenRequired: "Allowed. Reopen Zeus to start."
        case .denied, .revoked: "Input Monitoring is off for Zeus, so nothing you type is noted."
        }
    }
}

/// Only explicit consent requests Input Monitoring. An empty allow list is safe, including after picker cancellation.
@MainActor @Observable final class TypingPrivacyModel {
    let policies: ObservationSettings
    let privacy: LearnSettings
    var permission = TypingPermissionPresentation.notRequested
    var modelAvailable = false
    var secureInput = false
    var showsConsent = false
    var needsAppPicker = false
    private(set) var retentionCaption: String?
    var appResult: String?
    @ObservationIgnored var changed: () -> Void = {}
    @ObservationIgnored var requestPermission: () -> Void = {}
    @ObservationIgnored var openPermissionSettings: () -> Void = {}
    @ObservationIgnored var reopen: () -> Void = {}
    @ObservationIgnored var paused: () -> Bool = { false }
    @ObservationIgnored var shortenRetention: () -> Bool = { true }
    init(policies: ObservationSettings, privacy: LearnSettings) { self.policies = policies; self.privacy = privacy }
    var policy: ObservationPolicy { policies.policy(4) }
    var isEnabled: Bool { policy.enabled && policy.consented }
    var showsPrivateInput: Bool { isEnabled && secureInput }
    var statusCaption: String? {
        if !modelAvailable { return Self.modelCaption }
        if let caption = permission.caption { return caption }
        if showsPrivateInput { return "Paused: private input." }
        return isEnabled && paused() ? "Paused until tomorrow." : nil
    }
    static let modelCaption = "Typing needs Apple Intelligence, which removes names and numbers from what you type. Turn it on in System Settings › Apple Intelligence & Siri."
    var keepCaption: String { retentionCaption ?? "Topics are kept for \(policy.retentionDays) days. The words, with private details removed, are kept as you choose here." }
    func setEnabled(_ enabled: Bool) {
        guard !enabled || modelAvailable else { return }
        if enabled && !policy.consented { showsConsent = true; return }
        policies.edit(4) { $0.enabled = enabled }; changed()
    }
    func continueConsent() {
        guard showsConsent, modelAvailable else { return }
        policies.edit(4) { $0.enabled = true; $0.consented = true }
        needsAppPicker = policy.apps.isEmpty
        showsConsent = false; changed()
        if !needsAppPicker { completeAppSelection() }
    }
    func cancelConsent() { showsConsent = false }
    func completeAppSelection() {
        needsAppPicker = false
        guard isEnabled, !policies.typingPermissionRequested, permission != .granted, permission != .reopenRequired else { return }
        policies.typingPermissionRequested = true; permission = .waiting; requestPermission()
    }
    func addApp(_ app: ExcludedApp) {
        if privacy.excludedApps.contains(where: { candidate in app.bundleIDs.contains { candidate.matches(bundleID: $0, name: app.name) } }) {
            appResult = "\(app.name) is on your private list. Remove it there first."; return
        }
        guard !app.bundleIDs.isEmpty else { appResult = "Couldn't add this app."; return }
        if policy.apps.contains(where: { $0.id == app.id }) { appResult = "\(app.name) is already listed."; return }
        policies.edit(4) { $0.apps.append(app) }; appResult = "Added \(app.name)."; changed()
    }
    func setTopics(_ days: Int) {
        let previous = policy.retentionDays
        policies.edit(4) { $0.retentionDays = days }
        retentionCaption = nil
        if policy.retentionDays < previous {
            retentionCaption = shortenRetention() ? "Deleted topics older than \(policy.retentionDays) days." : "Couldn't remove expired typing. Try again."
        }
        changed()
    }
    func setWords(_ hours: Int) {
        let previous = policies.typingWordsHours
        policies.typingWordsHours = hours; retentionCaption = nil
        if policies.typingWordsHours < previous {
            if shortenRetention() {
                retentionCaption = policies.typingWordsHours == 0 ? "Deleted the kept words." : "Deleted words older than 24 hours."
            } else { retentionCaption = "Couldn't remove expired typing. Try again." }
        }
        changed()
    }
}
