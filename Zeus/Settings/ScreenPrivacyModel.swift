import Foundation
import Observation

/// App presentation of Screen Recording permission. Only an explicit consent action may request it.
enum ScreenPermissionPresentation: Equatable {
    case notRequested, waiting, granted, reopenRequired, denied, revoked
    var caption: String? {
        switch self {
        case .notRequested, .granted: nil
        case .waiting: "Waiting for Screen Recording permission."
        case .reopenRequired: "Allowed. Reopen Zeus to start taking pictures."
        case .denied, .revoked: "Screen Recording is off for Zeus, so no pictures are taken."
        }
    }
}

enum ScreenPausePresentation: Equatable {
    case videoCall, presenting, secureInput
    var caption: String {
        switch self {
        case .videoCall: "Paused: a video call is on"
        case .presenting: "Paused: presenting"
        case .secureInput: "Paused: a password field is active"
        }
    }
}

/// Per-level choices remain app-owned; the capture controller supplies permission and hard-stop facts.
@MainActor @Observable final class ScreenPrivacyModel {
    let policies: ObservationSettings
    let privacy: LearnSettings
    var permission = ScreenPermissionPresentation.notRequested
    var pauseReason: ScreenPausePresentation?
    var showsConsent = false
    var showsCoveringConfirmation = false
    var modelAvailable = true
    @ObservationIgnored var changed: () -> Void = {}
    @ObservationIgnored var requestPermission: () -> Void = {}
    @ObservationIgnored var openPermissionSettings: () -> Void = {}
    @ObservationIgnored var reopen: () -> Void = {}
    @ObservationIgnored var pause: () -> Void = {}
    @ObservationIgnored var resume: () -> Void = {}
    @ObservationIgnored var isPaused: () -> Bool = { false }

    init(policies: ObservationSettings, privacy: LearnSettings) { self.policies = policies; self.privacy = privacy }
    var policy: ObservationPolicy { policies.policy(3) }
    var isEnabled: Bool { policy.enabled && policy.consented }
    var statusCaption: String? { permission.caption ?? (isEnabled ? pauseReason?.caption : nil) }
    func setEnabled(_ enabled: Bool) {
        if enabled && !policy.consented { showsConsent = true; return }
        policies.edit(3) { $0.enabled = enabled }; changed()
    }
    func continueConsent() {
        guard showsConsent else { return }
        policies.edit(3) { $0.consented = true; $0.enabled = true }
        showsConsent = false; changed()
        guard !policies.screenPermissionRequested, permission != .granted, permission != .reopenRequired else { return }
        policies.screenPermissionRequested = true
        permission = .waiting; requestPermission()
    }
    func setCoverPictures(_ enabled: Bool) {
        if !enabled && privacy.coverPictures { showsCoveringConfirmation = true; return }
        privacy.coverPictures = enabled; changed()
    }
    func keepCovering() { showsCoveringConfirmation = false }
    func confirmUncoveredPictures() {
        guard showsCoveringConfirmation else { return }
        privacy.coverPictures = false; showsCoveringConfirmation = false; changed()
    }
    func cancelConsent() { showsConsent = false }
}
