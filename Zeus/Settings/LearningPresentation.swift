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
    private(set) var screen: ScreenLearningModel?
    private(set) var ask: AskAboutThisModel?
    private(set) var error: String?
    @ObservationIgnored private var source: (any FocusCaptureSource)?
    @ObservationIgnored private var journal: (any JournalStore)?
    @ObservationIgnored var presentationChanged: () -> Void = {}
    @ObservationIgnored var runtimeProblem: () -> String? = { nil }
    @ObservationIgnored var contextDidChange: () -> Void = {}
    @ObservationIgnored private var observing = false
    @ObservationIgnored private var retentionTask: Task<Void, Never>?

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
        focus?.invalidate(); screen?.invalidate(); ask?.invalidate(); learn.invalidatePendingCapture(); viewer?.forgetUndo()
        do {
            try journal?.delete(.all)
            learn.deleteEverything(); viewer?.reload(); error = nil
        } catch { self.error = "Couldn't delete the journal. Try again." }
    }
    var enabled: Bool { learn.settings.enabled || (policies.policy(2).enabled && policies.policy(2).consented) || (policies.policy(3).enabled && policies.policy(3).consented) }
    func install(journal: any JournalStore, rules: any RulesStore, redactor: any Redactor,
                 source: any FocusCaptureSource = MacFocusCaptureSource()) {
        focus?.stop()
        self.journal = journal; self.source = source
        (source as? MacFocusCaptureSource)?.onContextChange = { [weak self] in self?.captureContextChanged() }
        (source as? MacFocusCaptureSource)?.safariDetailsAllowed = { [weak policies] in policies?.policy(2).permitsSafariDetails ?? false }
        screen?.stop()
        if let frames = journal as? any FrameJournalStoring {
            screen = ScreenLearningModel(policies: policies, learn: learn, journal: frames, redactor: redactor, focus: source)
        }
        ask = AskAboutThisModel(policies: policies, privacy: learn.settings, source: source, redactor: redactor,
            paused: { [weak learn] in learn?.isPausedNow ?? true },
            captureScreen: { [weak self] in await self?.screen?.observer?.captureOnDemand() })
        let viewer = JournalViewerModel(journal: journal)
        self.viewer = viewer; self.rules = RulesPaneModel(store: rules, journal: viewer)
        focus = FocusObserver(source: source, policies: policies,
            privateApps: { [weak learn] in learn?.settings.excludedApps ?? ExcludedApp.defaults },
            paused: { [weak learn] in learn?.isPausedNow ?? true }) { app, record in
                let capturedAt = Date()
                let payload = await redactor.redact(JournalPayload(description: app.name, text: record.text))
                let item = JournalItem(time: capturedAt, level: .focus, app: app.bundleID, kind: .focus, payload: payload)
                return { try journal.append(item) }
            }
        viewer.beforeDelete = { [weak self] in self?.focus?.invalidate(); self?.screen?.invalidate(); self?.ask?.invalidate(); self?.learn.invalidatePendingCapture() }
        if !observing { observing = true; observeSettings(); observeRules() }
        settingsChanged(); scheduleRetention()
    }
    isolated deinit { retentionTask?.cancel() }
    func stop() { retentionTask?.cancel(); retentionTask = nil; focus?.stop(); screen?.stop(); ask?.invalidate(); (source as? MacFocusCaptureSource)?.onContextChange = nil; observing = false }
    /// Idempotent ledger adapter: the app has no route/transport heuristics, only the runtime's actual receipt.
    func recordContextReceipt(key: String, intent: ContextSendIntent) -> Bool {
        guard let journal, let receipt = intent.receipt else { return false }
        let id = "attached_" + intent.cardID
        do {
            var query = JournalQuery(); query.kinds = [.sentToAssistant]; query.limit = 100_000
            if try journal.items(matching: query).contains(where: { $0.id == id }) { return true }
            try journal.append(.init(id: id, time: receipt.deliveredAt, level: intent.kinds.contains("Picture") ? .screen : .focus,
                kind: .sentToAssistant, payload: .init(.init(description: "Attached: " + intent.kinds.joined(separator: ", "), text: intent.body,
                    details: ["kind": "attachments", "agent": receipt.agent, "sessionLabel": receipt.sessionLabel, "sessionID": receipt.sessionID]))))
            error = nil; return true
        } catch { self.error = "Couldn't save what was sent to your assistant. Zeus will try again."; return false }
    }
    func reportStoreError() { error = "Zeus couldn't open its private journal or rules. Nothing new will be recorded." }
    func settingsChanged() {
        learn.invalidatePendingCapture()
        focus?.invalidate(); ask?.invalidate(); screen?.settingsChanged()
        if policies.policy(2).enabled && policies.policy(2).consented { focus?.start() } else { focus?.stop() }
        pruneExpired()
        learn.captureCurrentActivity()
        presentationChanged(); contextDidChange()
    }
    func pruneExpired(now: Date = Date()) {
        var retention = JournalRetention()
        retention.activityDays = learn.settings.retentionDays
        retention.focusDays = policies.policy(2).retentionDays
        retention.descriptionDays = policies.policy(3).retentionDays
        do { try journal?.prune(retention: retention, now: now); error = nil }
        catch { self.error = "Couldn't remove expired journal records. Try again." }
    }
    private func scheduleRetention() {
        retentionTask?.cancel()
        retentionTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let now = Date()
                let next = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now)) ?? now.addingTimeInterval(86_400)
                do { try await Task.sleep(for: .seconds(max(1, next.timeIntervalSince(now)))) } catch { return }
                self?.pruneExpired()
            }
        }
    }
    private func captureContextChanged() {
        focus?.invalidate(); screen?.contextChanged(); ask?.invalidate(); learn.invalidatePendingCapture(); contextDidChange()
    }
    var context: LearningContext {
        guard enabled, let source else { return .init(isPrivate: true) }
        let app = source.application
        let privateContext = source.isSecure || source.isLocked || learn.isPausedNow || app == nil
            || app?.bundleID == "com.colinc86.Zeus" || app?.bundleID.hasPrefix("local.zeus.") == true
            || (app.map { app in
                let globalPrivate = learn.settings.excludedApps.contains { $0.matches(bundleID: app.bundleID, name: app.name) }
                let l1 = learn.settings.enabled && policies.policy(1).allows(bundleID: app.bundleID, name: app.name, privateApps: learn.settings.excludedApps)
                let l2 = policies.policy(2).enabled && policies.policy(2).allows(bundleID: app.bundleID, name: app.name, privateApps: learn.settings.excludedApps)
                let l3 = policies.policy(3).enabled && policies.policy(3).consented && policies.policy(3).allows(bundleID: app.bundleID, name: app.name, privateApps: learn.settings.excludedApps)
                return globalPrivate || (!l1 && !l2 && !l3)
            } ?? true)
        let seconds = source.idleSeconds
        return LearningContext(frontmostApp: privateContext ? nil : app?.bundleID,
                               idleSince: privateContext ? nil : Date().addingTimeInterval(-(seconds.isFinite ? max(0, seconds) : 0)),
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
            _ = policies.policy(1); _ = policies.policy(2); _ = policies.policy(3); _ = policies.screenPerHour
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
