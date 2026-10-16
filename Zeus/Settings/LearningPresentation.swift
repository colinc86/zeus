import AppKit
import Foundation
import FoundationModels
import Observation
import ZeusProtocol

/// Owns app-side opt-ins and presentation. Concrete encrypted stores are created by the app delegate, never by test shells.
@MainActor @Observable
final class LearningPresentation {
    let policies: ObservationSettings
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored let learn: LearnFromMe
    let folder = LearningFolderModel()
    var deliveries: LearningDeliveryModel? { didSet { viewer?.deliveries = deliveries } }
    private(set) var viewer: JournalViewerModel?
    private(set) var rules: RulesPaneModel?
    private(set) var focus: FocusObserver?
    private(set) var screen: ScreenLearningModel?
    private(set) var typing: TypingLearningModel?
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
        self.defaults = defaults
        self.policies = policies ?? ObservationSettings(defaults: defaults); self.learn = learn
        let policies = self.policies
        learn.settings.permitsApp = { [weak learn] id, name in
            id != "com.colinc86.Zeus" && id?.hasPrefix("local.zeus.") != true
                && policies.policy(1).allows(bundleID: id, name: name, privateApps: learn?.settings.excludedApps ?? ExcludedApp.defaults)
        }
    }
    static let storageWaitingMessage = "Zeus can't open its journal and rules right now. New records are kept only in memory until it can; quitting Zeus before then loses them."
    /// Store warnings remain independent of capture permissions and transient runtime errors.
    var storageWarnings: [String] {
        var warnings: [String] = []
        for (error, recovery) in [(journal?.lastError, journal as? any LearningStorageRecovering),
                                  (rules?.store.lastError, rules?.store as? any LearningStorageRecovering)] {
            let presentedError = error == LearningStorageAvailability.waitingMessage ? Self.storageWaitingMessage : error
            let warning = presentedError ?? ((recovery?.storageWaitingForUnlock == true || (recovery?.pendingStorageWrites ?? 0) > 0)
                ? Self.storageWaitingMessage : nil)
            if let warning, !warnings.contains(warning) { warnings.append(warning) }
        }
        return warnings
    }
    /// Unlock and session activation supplement the stores' own bounded retry timers; never request a key or permission here.
    func retryLearningStorage() {
        var attemptedRecovery = false
        for recovery in [journal as? any LearningStorageRecovering, rules?.store as? any LearningStorageRecovering].compactMap({ $0 }) {
            if recovery.storageWaitingForUnlock || recovery.pendingStorageWrites > 0 {
                attemptedRecovery = true
                recovery.retryPendingWrites()
            }
        }
        if attemptedRecovery { viewer?.reload() }
    }
    var redactionCaption: String {
        let prefix = "Private details are removed on this Mac before anything is kept."
        if SystemLanguageModel.default.isAvailable { return prefix }
        return prefix + " Apple Intelligence is off, so Zeus catches names, emails, phone numbers, addresses, passwords, keys, card and account numbers and ID numbers, and may miss private details written in other ways."
    }
    func deleteEverything(includeAssistantNotes: Bool = false) {
        focus?.invalidate(); screen?.invalidate(); typing?.invalidate(); ask?.invalidate(); learn.invalidatePendingCapture(); viewer?.forgetUndo()
        // Persist the erase boundary before deleting, so an old receipt cannot restore the sent ledger after relaunch.
        let previousBoundary = defaults.object(forKey: "learn.contextLedgerClearedAt")
        defaults.set(Date(), forKey: "learn.contextLedgerClearedAt")
        do {
            try journal?.delete(.all)
            learn.deleteEverything(); viewer?.reload()
            do {
                try (folder.provider as? any LearningFolderErasing)?.deleteFolderContents(includeAssistantNotes: includeAssistantNotes)
                error = nil
            } catch { self.error = "Couldn't finish deleting the folder contents. Try again." }
        } catch {
            if let previousBoundary { defaults.set(previousBoundary, forKey: "learn.contextLedgerClearedAt") }
            else { defaults.removeObject(forKey: "learn.contextLedgerClearedAt") }
            self.error = "Couldn't delete the journal. Try again."
        }
    }
    var journalAccessPolicy: JournalAccessPolicy {
        var enabled: Set<JournalLevel> = []
        if learn.settings.enabled { enabled.insert(.activity) }
        for level in [JournalLevel.focus, .screen, .typed] {
            let policy = policies.policy(level.rawValue)
            if policy.enabled && policy.consented { enabled.insert(level) }
        }
        return JournalAccessPolicy(enabledLevels: enabled, rawLevels: enabled)
    }
    /// Exact durable receipts outrank a pending snapshot after a ledger write failure.
    /// Nil means the journal is unavailable, not that no receipt exists.
    var receivedLearningDeliveryIDs: Set<String>? {
        guard let journal else { return nil }
        _ = journal.revision
        var query = JournalQuery(); query.kinds = [.sentToAssistant]; query.limit = 100_000
        return try? Set(journal.items(matching: query).compactMap { $0.payload.value.details["delivery_id"] })
    }
    var enabled: Bool { learn.settings.enabled || (2...4).contains { policies.policy($0).enabled && policies.policy($0).consented } }
    /// Read only when building the menu; no notification, announcement, avatar state or thread entry is emitted.
    var privateInputMenuLine: String? {
        policies.policy(4).enabled && policies.policy(4).consented && (source?.isSecure == true || typing?.privacy.secureInput == true)
            ? "Private input: Zeus isn't noting typing" : nil
    }
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
        typing?.stop(); typing = nil
        if let typingJournal = journal as? any TypingJournalStoring {
            typing = TypingLearningModel(policies: policies, learn: learn, journal: typingJournal, redactor: redactor, focus: source)
            typing?.privacy.shortenRetention = { [weak self] in self?.pruneExpired() ?? false }
        }
        ask = AskAboutThisModel(policies: policies, privacy: learn.settings, source: source, redactor: redactor,
            paused: { [weak learn] in learn?.isPausedNow ?? true },
            captureScreen: { [weak self] in await self?.screen?.observer?.captureOnDemand() })
        // Apply local retention before a viewer can cache any words under a longer/default preference.
        pruneExpired()
        let viewer = JournalViewerModel(journal: journal)
        viewer.deliveries = deliveries
        viewer.folder = folder
        viewer.learningEnabled = { [weak self] in self?.enabled ?? false }
        self.viewer = viewer; self.rules = RulesPaneModel(store: rules, journal: viewer)
        focus = FocusObserver(source: source, policies: policies,
            privateApps: { [weak learn] in learn?.settings.excludedApps ?? ExcludedApp.defaults },
            paused: { [weak learn] in learn?.isPausedNow ?? true }) { app, record in
                let capturedAt = Date()
                let payload = await redactor.redact(JournalPayload(description: app.name, text: record.text))
                let item = JournalItem(time: capturedAt, level: .focus, app: app.bundleID, kind: .focus, payload: payload)
                return { try journal.append(item) }
            }
        viewer.beforeDelete = { [weak self] in self?.focus?.invalidate(); self?.screen?.invalidate(); self?.typing?.invalidate(); self?.ask?.invalidate(); self?.learn.invalidatePendingCapture() }
        if !observing { observing = true; observeSettings(); observeRules() }
        settingsChanged(); scheduleRetention()
    }
    isolated deinit { retentionTask?.cancel() }
    func stop() { retentionTask?.cancel(); retentionTask = nil; focus?.stop(); screen?.stop(); typing?.stop(); ask?.invalidate(); (source as? MacFocusCaptureSource)?.onContextChange = nil; observing = false }
    /// Idempotent ledger adapter: the app has no route/transport heuristics, only the runtime's actual receipt.
    func recordContextReceipt(key: String, intent: ContextSendIntent) -> Bool {
        guard let journal, let receipt = intent.receipt else { return false }
        if let clearedAt = defaults.object(forKey: "learn.contextLedgerClearedAt") as? Date, receipt.deliveredAt <= clearedAt { return true }
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
        focus?.invalidate(); ask?.invalidate(); screen?.settingsChanged(); typing?.settingsChanged()
        if policies.policy(2).enabled && policies.policy(2).consented { focus?.start() } else { focus?.stop() }
        pruneExpired()
        learn.captureCurrentActivity()
        presentationChanged(); contextDidChange()
    }
    @discardableResult func pruneExpired(now: Date = Date()) -> Bool {
        var retention = JournalRetention()
        retention.activityDays = learn.settings.retentionDays
        retention.focusDays = policies.policy(2).retentionDays
        retention.descriptionDays = policies.policy(3).retentionDays
        retention.typedDays = policies.policy(4).retentionDays
        do {
            try journal?.prune(retention: retention, now: now)
            let words: TypingWordsRetention = switch policies.typingWordsHours { case 0: .none; case 168: .week; default: .day }
            try (journal as? any TypingJournalStoring)?.pruneTyping(words: words, topicsDays: policies.policy(4).retentionDays, now: now)
            viewer?.reload(); error = nil; return true
        } catch { viewer?.reload(); self.error = "Couldn't remove expired journal records. Try again."; return false }
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
        focus?.invalidate(); screen?.contextChanged(); typing?.contextChanged(); ask?.invalidate(); learn.invalidatePendingCapture(); contextDidChange()
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
                let l4 = policies.policy(4).enabled && policies.policy(4).consented && policies.policy(4).allows(bundleID: app.bundleID, name: app.name, privateApps: learn.settings.excludedApps)
                return globalPrivate || (!l1 && !l2 && !l3 && !l4)
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
            _ = policies.policy(1); _ = policies.policy(2); _ = policies.policy(3); _ = policies.policy(4); _ = policies.screenPerHour; _ = policies.typingWordsHours
            _ = learn.settings.enabled; _ = learn.settings.pausedUntil
            _ = learn.settings.excludedApps; _ = learn.settings.retentionDays; _ = learn.settings.coverPictures
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.observing else { return }
                self.settingsChanged(); self.observeSettings()
            }
        }
    }
}
