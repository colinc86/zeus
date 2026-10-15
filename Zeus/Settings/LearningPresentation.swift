import AppKit
import Foundation
import FoundationModels
import Observation
import ZeusProtocol

/// Owns app-side opt-ins and presentation. Concrete encrypted stores are created by the app delegate, never by test shells.
@MainActor @Observable
final class LearningPresentation {
    let policies: ObservationSettings
    @ObservationIgnored let learn: LearnFromMe
    private(set) var viewer: JournalViewerModel?
    private(set) var rules: RulesPaneModel?
    private(set) var focus: FocusObserver?
    private(set) var error: String?
    @ObservationIgnored private var source: (any FocusCaptureSource)?
    @ObservationIgnored private var journal: (any JournalStore)?
    @ObservationIgnored private var workspace: WorkspaceActivitySource?
    @ObservationIgnored var presentationChanged: () -> Void = {}
    @ObservationIgnored var contextDidChange: () -> Void = {}
    @ObservationIgnored private var observing = false

    init(defaults: UserDefaults, learn: LearnFromMe, policies: ObservationSettings? = nil) {
        self.policies = policies ?? ObservationSettings(defaults: defaults); self.learn = learn
        let policies = self.policies
        learn.settings.permitsApp = { [weak learn] id, name in
            id != "com.colinc86.Zeus" && id?.hasPrefix("local.zeus.") != true
                && policies.policy(1).allows(bundleID: id, name: name, privateApps: learn?.settings.excludedApps ?? ExcludedApp.defaults)
        }
    }
    var redactionCaption: String {
        let prefix = "Private details are removed on this Mac before anything is kept."
        if SystemLanguageModel.default.isAvailable { return prefix }
        return prefix + " Apple Intelligence is off, so only fixed patterns (emails, card numbers, passwords…) are caught."
    }
    func deleteEverything() {
        focus?.invalidate(); learn.invalidatePendingCapture(); viewer?.forgetUndo()
        do {
            try journal?.delete(.all)
            learn.deleteEverything(); viewer?.reload(); error = nil
        } catch { self.error = "Couldn't delete the journal. Try again." }
    }
    var enabled: Bool { learn.settings.enabled || policies.policy(2).enabled }
    func install(journal: any JournalStore, rules: any RulesStore, redactor: any Redactor,
                 source: any FocusCaptureSource = MacFocusCaptureSource()) {
        focus?.stop()
        self.journal = journal; self.source = source
        (source as? MacFocusCaptureSource)?.safariDetailsAllowed = { [weak policies] in policies?.policy(2).permitsSafariDetails ?? false }
        let viewer = JournalViewerModel(journal: journal)
        self.viewer = viewer; self.rules = RulesPaneModel(store: rules, journal: viewer)
        focus = FocusObserver(source: source, policies: policies,
            privateApps: { [weak learn] in learn?.settings.excludedApps ?? ExcludedApp.defaults },
            paused: { [weak learn] in learn?.isPausedNow ?? true }) { app, record in
                let payload = await redactor.redact(JournalPayload(description: app.name, text: record.text))
                let item = JournalItem(level: .focus, app: app.bundleID, kind: .focus, payload: payload)
                return { try journal.append(item) }
            }
        viewer.beforeDelete = { [weak self] in self?.focus?.invalidate(); self?.learn.invalidatePendingCapture() }
        if !observing { observing = true; observeSettings(); observeRules() }
        settingsChanged()
    }
    func stop() { focus?.stop(); workspace?.stop(); workspace = nil; observing = false }
    func reportStoreError() { error = "Zeus couldn't open its private journal or rules. Nothing new will be recorded." }
    func settingsChanged() {
        focus?.invalidate()
        if policies.policy(2).enabled && policies.policy(2).consented { focus?.start() } else { focus?.stop() }
        var retention = JournalRetention()
        retention.activityDays = learn.settings.retentionDays
        retention.focusDays = policies.policy(2).retentionDays
        do { try journal?.prune(retention: retention, now: Date()); error = nil }
        catch { self.error = "Couldn't remove expired journal records. Try again." }
        if enabled && workspace == nil {
            let workspace = WorkspaceActivitySource(); self.workspace = workspace
            workspace.start { [weak self] _ in self?.contextDidChange() }
        } else if !enabled { workspace?.stop(); workspace = nil }
        presentationChanged(); contextDidChange()
    }
    var context: LearningContext {
        guard enabled, let source else { return .init(isPrivate: true) }
        let app = source.application
        let privateContext = source.isSecure || source.isLocked || learn.isPausedNow || app == nil
            || app?.bundleID == "com.colinc86.Zeus" || app?.bundleID.hasPrefix("local.zeus.") == true
            || (app.map { learn.settings.isExcluded(bundleID: $0.bundleID, name: $0.name) } ?? true)
        let seconds = WorkspaceActivitySource().secondsSinceLastInput
        return LearningContext(frontmostApp: privateContext ? nil : app?.bundleID,
                               idleSince: seconds >= 600 ? Date().addingTimeInterval(-seconds) : nil,
                               isLocked: source.isLocked, isPrivate: privateContext)
    }
    private func observeRules() {
        guard observing else { return }
        withObservationTracking { _ = rules?.store.revision } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.observing else { return }
                self.presentationChanged(); self.observeRules()
            }
        }
    }
    private func observeSettings() {
        guard observing else { return }
        withObservationTracking {
            _ = policies.policy(1); _ = policies.policy(2)
            _ = learn.settings.enabled; _ = learn.settings.pausedUntil
            _ = learn.settings.excludedApps; _ = learn.settings.retentionDays
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.observing else { return }
                self.settingsChanged(); self.observeSettings()
            }
        }
    }
}
