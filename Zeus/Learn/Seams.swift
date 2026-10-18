import Foundation

// Learning integration seams (CONTRACT §13). Platform-owned; app adapters remain optional.

/// Placeholders carry a category, never the removed text.
enum RedactionKind: String, Codable, CaseIterable, Sendable {
    case email, phone, card, iban, identity, secret, address, name, health, finance
    var placeholder: String { "‹\(rawValue)›" }
}
struct RedactionReport: Codable, Equatable, Sendable {
    enum SemanticEngine: String, Codable, Sendable { case onDeviceModel, naturalLanguage, patternsOnly }
    var counts: [RedactionKind: Int] = [:]
    var semanticEngine: SemanticEngine = .patternsOnly
    var total: Int { counts.values.reduce(0, +) }
}
/// A redaction result, not a raw observation. Construct only in redactors or synthetic test doubles.
/// No raw input, removed span text or model error message is retained in this value.
struct Redacted<Value: Codable & Sendable>: Codable, Sendable {
    let value: Value
    let report: RedactionReport
    init(_ value: Value, report: RedactionReport = .init()) { self.value = value; self.report = report }
}
extension Redacted: Equatable where Value: Equatable {}

/// On-device only. User-content strings are redacted before JournalStore.append; system metadata stays exact.
protocol Redactor: Sendable {
    func redact(_ text: String) async -> Redacted<String>
    func redact(_ payload: JournalPayload) async -> Redacted<JournalPayload>
}
extension Redactor {
    func redact(_ payload: JournalPayload) async -> Redacted<JournalPayload> {
        let description = await redact(payload.description)
        let text = await payload.text.asyncMap { await redact($0) }
        let topic = await payload.topic.asyncMap { await redact($0) }
        var details: [String: String] = [:]
        var report = description.report
        func merge(_ other: RedactionReport) {
            for (kind, count) in other.counts { report.counts[kind, default: 0] += count }
            if other.semanticEngine == .onDeviceModel { report.semanticEngine = .onDeviceModel }
            else if report.semanticEngine == .patternsOnly { report.semanticEngine = other.semanticEngine }
        }
        if let text { merge(text.report) }
        if let topic { merge(topic.report) }
        // Keys are schema constants; only explicitly system-sourced values bypass redaction.
        for key in payload.details.keys.sorted() {
            let value = payload.details[key] ?? ""
            if JournalPayload.systemDetailKeys.contains(key) { details[key] = value }
            else { let safe = await redact(value); details[key] = safe.value; merge(safe.report) }
        }
        return .init(.init(description: description.value, text: text?.value, topic: topic?.value, details: details), report: report)
    }
}
private extension Optional where Wrapped == String {
    func asyncMap<T>(_ transform: (String) async -> T) async -> T? {
        guard let value = self else { return nil }; return await transform(value)
    }
}

enum JournalLevel: Int, Codable, CaseIterable, Sendable { case activity = 1, focus = 2, screen = 3, typed = 4 }
enum JournalKind: String, Codable, CaseIterable, Sendable {
    case activity, focus, description, frame, typedText, outcome, reflection, sentToAssistant
}
/// Text metadata only. Image bytes require FrameJournalStoring.appendFrame after image redaction.
struct JournalPayload: Codable, Equatable, Sendable {
    /// OS identity and Zeus-generated metadata only. Unknown values remain user content.
    static let systemDetailKeys: Set<String> = [
        "appName", "name", "bundleID", "app", "frame_id", "run_id",
        "descriptionEngine", "topicEngine", "inputMethod", "kind", "level", "intent",
        "keyCount", "pasteCount", "wordCount", "count", "seconds", "duration", "displays",
        "words_not_kept", "picture_not_kept", "words_expires", "topic_expires"
    ]

    var description: String
    var text: String?
    /// Level 4 summary, distinct from locally retained words. Older journal rows decode this as nil.
    var topic: String?
    var details: [String: String]
    init(description: String, text: String? = nil, topic: String? = nil, details: [String: String] = [:]) {
        self.description = description; self.text = text; self.topic = topic; self.details = details
    }
}
struct JournalItem: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let time: Date
    let level: JournalLevel
    /// Bundle identifier only, not an app/window display name or document URL.
    let app: String?
    let kind: JournalKind
    let payload: Redacted<JournalPayload>
    init(id: String = UUID().uuidString, time: Date = Date(), level: JournalLevel, app: String? = nil,
         kind: JournalKind, payload: Redacted<JournalPayload>) {
        self.id = id; self.time = time; self.level = level; self.app = app; self.kind = kind; self.payload = payload
    }
}
struct JournalQuery: Equatable, Sendable {
    var from: Date?
    var to: Date?
    var levels: Set<JournalLevel> = []
    var apps: Set<String> = []
    var kinds: Set<JournalKind> = []
    var text = ""
    var limit = 500
}
enum JournalDeletion: Sendable { case item(String), day(Date), app(String), all }
struct JournalRetention: Codable, Equatable, Sendable {
    var activityDays = 90
    var focusDays = 90
    var frameDays = 7
    var descriptionDays = 90
    var typedDays = 30
}
/// Per-day authenticated encryption; implementations inject their key provider in tests (never use the real Keychain).
@MainActor protocol JournalStore: AnyObject {
    /// Concrete stores use Observation. Changes and errors are independently observable.
    var revision: UInt64 { get }
    var lastError: String? { get }
    /// Revalidate capture guards after redaction, then append in the SAME main-actor turn (no intervening await).
    func append(_ item: JournalItem) throws
    func items(matching query: JournalQuery) throws -> [JournalItem]
    func delete(_ selection: JournalDeletion) throws
    func export(matching query: JournalQuery) throws -> Data
    func prune(retention: JournalRetention, now: Date) throws
}

enum TypingWordsRetention: String, Codable, CaseIterable, Sendable {
    case none, day, week
    var hours: Int { switch self { case .none: 0; case .day: 24; case .week: 168 } }
}
/// Optional capability: discard words independently of topics, atomically per stretch; other levels are untouched.
@MainActor protocol TypingJournalStoring: JournalStore {
    func pruneTyping(words: TypingWordsRetention, now: Date) throws
    func pruneTyping(words: TypingWordsRetention, topicsDays: Int, now: Date) throws
    /// One atomic day transaction. App/hour groups share a day; cross-day selections fail before mutation.
    func deleteTyping(ids: Set<String>) throws -> TypingDeletionReceipt
    func restoreTyping(_ receipt: TypingDeletionReceipt) throws
}
/// In-memory Undo token, scoped to this store instance and its current forget epoch.
struct TypingDeletionReceipt: Sendable {
    let epoch: UUID
    let items: [JournalItem]
}
enum TypingJournalError: Error, LocalizedError {
    case unsupported, notFound, conflict, expired
    var errorDescription: String? {
        switch self {
        case .unsupported: "This journal can't change a typing group."
        case .notFound: "This typing group is no longer available."
        case .conflict: "This typing group has changed."
        case .expired: "This typing group has expired."
        }
    }
}
extension TypingJournalStoring {
    func pruneTyping(words: TypingWordsRetention, topicsDays: Int, now: Date) throws {
        try pruneTyping(words: words, now: now)
    }
    func deleteTyping(ids: Set<String>) throws -> TypingDeletionReceipt { throw TypingJournalError.unsupported }
    func restoreTyping(_ receipt: TypingDeletionReceipt) throws { throw TypingJournalError.unsupported }
}

struct RuleTimeWindow: Codable, Equatable, Sendable {
    /// Local minutes after midnight, 0..<1440; a wrapping range crosses midnight.
    var startMinute: Int
    var endMinute: Int
    /// Calendar weekdays 1...7; empty means every day.
    var weekdays: Set<Int> = []
}
struct RuleTrigger: Codable, Equatable, Sendable {
    /// Spending never grants standing payment authority; each purchase needs a separate answer.
    var kind: String? = nil
    var time: RuleTimeWindow?
    /// Bundle identifiers. Empty means any app; specified dimensions combine with AND.
    var apps: Set<String> = []
    /// Explicit context facts, e.g. "tests failing". An unknown fact never matches.
    var state: String?
}
enum LearnedRuleKind: String, Codable, Sendable { case passive, acts }
enum LearnedRuleStatus: String, Codable, CaseIterable, Sendable { case active, proposed, shadow, retired }
enum RuleAuthor: String, Codable, Sendable { case agent, user }
struct RuleProposal: Codable, Equatable, Sendable {
    var sentence: String
    var trigger: RuleTrigger = .init()
    var kind: LearnedRuleKind = .passive
    var confidence: Double = 0.6
    var evidence: [String] = []
}
struct LearnedRule: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var sentence: String
    var trigger: RuleTrigger
    var kind: LearnedRuleKind
    var status: LearnedRuleStatus
    var confidence: Double
    var evidence: [String]
    let created: Date
    var updated: Date
    var updatedBy: RuleAuthor
    /// Original authorship; legacy rows conservatively use updatedBy. Toggles do not change this.
    var author: RuleAuthor? = nil
}
enum RuleOutcome: String, Codable, Sendable { case accepted, skipped, undone, ignored, toggledOff, toggledOn, edited, stale }
/// Shared by Settings and runtime. Concrete stores publish mutations with Observation.
/// Agent proposals may only create passive/active or acts/shadow rules, never activate an act.
@MainActor protocol RulesStore: AnyObject {
    var rules: [LearnedRule] { get }
    var revision: UInt64 { get }
    var lastError: String? { get }
    /// 0 = Ask me first, 1 = Just do it. Never bypasses shadow approval or app authority boundaries.
    var autonomy: Double { get set }
    func propose(_ proposals: [RuleProposal], at now: Date) throws -> [LearnedRule]
    /// Explicit user creation, atomically marked .user.
    func addOwn(_ proposal: RuleProposal, at now: Date) throws -> LearnedRule
    func setStatus(_ status: LearnedRuleStatus, id: String, at now: Date) throws
    func edit(id: String, sentence: String, trigger: RuleTrigger, at now: Date) throws
    /// Restores a user-deleted rule exactly (including identity and evidence) for Undo.
    func restoreDeleted(_ rule: LearnedRule) throws
    func delete(id: String) throws
    func recordOutcome(_ outcome: RuleOutcome, ruleIDs: [String], at now: Date) throws
    /// Stable event IDs prevent re-counting a recovered Skip/Undo/ignored result.
    func recordOutcome(_ outcome: RuleOutcome, ruleIDs: [String], eventID: String, at now: Date) throws
}
extension RulesStore {
    func recordOutcome(_ outcome: RuleOutcome, ruleIDs: [String], eventID: String, at now: Date) throws {
        try recordOutcome(outcome, ruleIDs: ruleIDs, at: now)
    }
}

/// Current permitted context only. Supply explicit facts; unknown/private context never matches an app/state trigger.
struct LearningContext: Equatable, Sendable {
    var frontmostApp: String?
    var states: Set<String> = []
    var idleSince: Date?
    var isLocked = false
    var isPrivate = false
}
struct LearningNotice: Equatable, Identifiable, Sendable {
    enum Kind: String, Sendable { case newRule, shadow, reflection }
    let id: String
    let kind: Kind
    let createdAt: Date
    let summary: String
    let actionTitle: String?
    let detail: String?
    let ruleID: String?
    var deliveryKindName: String? = nil
}
/// App-owned adapter to CardStore.recordNotice; these lines NEVER peek, badge or play a sound.
@MainActor protocol LearningNoticeRecording: AnyObject {
    /// Repeated IDs reconnect the action after relaunch without duplicating the persisted line.
    @discardableResult func recordLearningNotice(_ notice: LearningNotice, action: (@MainActor () -> Void)?) -> Bool
    @discardableResult func recordLearningNotice(_ notice: LearningNotice, action: (@MainActor () -> Void)?,
                                                 secondaryTitle: String?, secondary: (@MainActor () -> Void)?) -> Bool
}
/// Optional runtime capability; no Shared seam edit is needed for Phase A composition.
@MainActor protocol LearningRuntimeControlling: AnyObject {
    var learningInterruptionHold: Bool { get }
    var learningError: String? { get }
    var onReviewRule: ((String) -> Void)? { get set }
    /// App replays the newest still-unread held card, with normal visibility/quiet-hours checks.
    var onLearningHoldCleared: (([String]) -> Void)? { get set }
    /// Call after context/enable changes. Runtime also schedules time-window/idle boundaries itself.
    func learningContextDidChange()
    /// App-owned Undo paths may report an outcome without exposing their action closures to the agent.
    func recordLearningOutcome(_ outcome: RuleOutcome, ruleIDs: [String])
}

/// Durable runtime bookkeeping, kept out of the UI mutation API.
@MainActor protocol LearningRuleTracking: AnyObject {
    func associate(cardID: String, ruleIDs: [String]) throws
    func associatedRuleIDs(cardID: String) -> [String]
    func markShadowShown(id: String) throws -> Bool
    func hasShadowShown(id: String) -> Bool
    func ruleNoticeGroups() -> [[String]]
    func undoShadowApproval(id: String, at now: Date) throws
}
extension RuleTrigger {
    /// Unconstrained rules guide the assistant, never hold the UI indefinitely.
    var isEvaluable: Bool { time != nil || !apps.isEmpty || state != nil }
    func matches(_ context: LearningContext, at date: Date, calendar: Calendar = .current) -> Bool {
        guard isEvaluable else { return false }
        // Civil time remains known with capture off/private; only app/state facts require permitted context.
        if (!apps.isEmpty || state != nil) && (context.isLocked || context.isPrivate) { return false }
        if !apps.isEmpty, !apps.contains(context.frontmostApp ?? "") { return false }
        if let state, !context.states.contains(state) { return false }
        if let time {
            let minute = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
            let wraps = time.startMinute > time.endMinute
            let inside = time.startMinute == time.endMinute || (wraps ? minute >= time.startMinute || minute < time.endMinute : minute >= time.startMinute && minute < time.endMinute)
            guard inside else { return false }
            let weekdayDate = wraps && minute < time.endMinute ? calendar.date(byAdding: .day, value: -1, to: date) ?? date : date
            if !time.weekdays.isEmpty, !time.weekdays.contains(calendar.component(.weekday, from: weekdayDate)) { return false }
        }
        return true
    }
}

/// Runtime subscribes while active. Feedback contains generated categories/IDs only, never card text or raw observations.
@MainActor protocol LearningRuleOutcomeSource: AnyObject {
    var onRuleOutcome: ((RuleOutcome, [String], String, Date) -> Void)? { get set }
}

// Phase B values stay Foundation-only so headless runtime hosts can compile these seams.
/// Normalized top-left coordinates, relative to the kept preview (0...1).
struct FrameBox: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case text, picture, face }
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var kind: Kind
}
/// Already-covered preview bytes only. No source image or removed OCR text is retained.
struct FrameItem: Codable, Equatable, Sendable {
    var heic: Data
    var width: Int
    var height: Int
    var boxes: [FrameBox]
    var appName: String
    var windowTitle: String
}
/// Optional journal capability. Frame IDs equal their .frame JournalItem IDs; descriptions link via details["frame_id"].
/// Query/export return text metadata, never image bytes. Only explicit local viewer/attachment actions read a frame.
@MainActor protocol FrameJournalStoring: JournalStore {
    func appendFrame(_ frame: Redacted<FrameItem>, item: JournalItem) throws
    func frame(id: String) throws -> Redacted<FrameItem>?
    /// Applies only screen retention; never changes another capture level's retention.
    func pruneScreens(descriptionDays: Int, now: Date) throws
    @discardableResult func deleteFrame(id: String, includingDescription: Bool) throws -> FrameDeletionReceipt
    func restoreFrame(_ receipt: FrameDeletionReceipt) throws
}

extension FrameJournalStoring {
    func pruneScreens(descriptionDays: Int, now: Date) throws {
        var query = JournalQuery(); query.levels = [.screen]; query.limit = 100_000
        for item in try items(matching: query) {
            let days = item.kind == .frame ? 7 : ([7, 30, 90].contains(descriptionDays) ? descriptionDays : 90)
            let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Calendar.current.startOfDay(for: now)) ?? now
            if item.time < cutoff { try delete(.item(item.id)) }
        }
    }
}

/// An in-memory Undo token, already redacted. Restore compares the post-delete rows before replacing them.
struct FrameDeletionReceipt: Sendable {
    let frameID: String
    let epoch: UUID
    let frame: Redacted<FrameItem>?
    let before: [JournalItem]
    let after: [JournalItem]
}
enum FrameJournalError: Error, LocalizedError {
    case unsupported, conflict, notFound
    var errorDescription: String? {
        switch self {
        case .unsupported: "This journal doesn't support picture changes."
        case .conflict: "The picture or its description changed. Undo wasn't applied."
        case .notFound: "This picture is no longer kept."
        }
    }
}
extension FrameJournalStoring {
    func deleteFrame(id: String, includingDescription: Bool) throws -> FrameDeletionReceipt { throw FrameJournalError.unsupported }
    func restoreFrame(_ receipt: FrameDeletionReceipt) throws { throw FrameJournalError.unsupported }
}

/// Actual consumed/write receipt, never an attempt. App filters for explicit context chips before journaling.
/// No raw session key/path is exposed; body/attachment labels come from the app's already-saved Send intent.
struct LearningContextDeliveryReceipt: Sendable {
    let deliveryID: String
    let cardID: String?
    let deliveredAt: Date
    let agent: String
    let sessionLabel: String
    let sessionID: String
}
@MainActor protocol LearningContextReceiptRecording: AnyObject {
    /// May replay after relaunch. Deduplicate by the app's stable context/card/delivery ID, never current routing settings.
    func recordLearningContextReceipt(_ receipt: LearningContextDeliveryReceipt)
}


// Phase D optional capabilities. All journal access is denied until the app installs a consent policy.
struct JournalAccessPolicy: Equatable, Sendable {
    var enabledLevels: Set<JournalLevel> = []
    /// Only .screen and .typed are meaningful; even raw means covered pictures / redacted words.
    /// Legacy UI compatibility only. LF1 raw access follows enabledLevels.
    var rawLevels: Set<JournalLevel> = []
}
@MainActor protocol LearningJournalAccessControlling: AnyObject {
    var journalAccessPolicy: () -> JournalAccessPolicy { get set }
    /// Opens the sent ledger at the durable answer ID supplied by the runtime.
    var onViewJournalAnswer: ((String) -> Void)? { get set }
}
/// Two-action support is optional for older app adapters. Settings always remains a decline path.
extension LearningNoticeRecording {
    @discardableResult func recordLearningNotice(_ notice: LearningNotice, action: (@MainActor () -> Void)?,
                                                 secondaryTitle: String?, secondary: (@MainActor () -> Void)?) -> Bool {
        recordLearningNotice(notice, action: action)
    }
}

/// A specific cause disambiguates explicit consent from implicit acceptance. IDs are durable and idempotent.
enum RuleOutcomeSource: String, Codable, Sendable {
    case explicit, actedUnchanged, heldRead, holdShown, timedQuestion, shadowDeclined, shadowIgnored, resultIgnored, stale
}
struct RuleOutcomeEvent: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let ruleID: String
    let at: Date
    let outcome: RuleOutcome
    let source: RuleOutcomeSource
    let delta: Double
}
struct RuleSuppression: Codable, Equatable, Sendable {
    let fingerprint: String
    let sentence: String
    let trigger: RuleTrigger
    let until: Date
    let reason: String
}
struct RuleActionRecord: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case shadow, acted }
    enum State: String, Codable, Sendable { case pending, approved, declined, undoRequested, off, ignored, settled }
    var id: String
    var ruleID: String
    var sessionKey: String
    var text: String
    var undo: String?
    var created: Date
    var kind: Kind
    var state: State = .pending
    var approvalCardID: String? = nil
    var amount: Double? = nil
    var currency: String? = nil
}
/// Optional durable outcome/action API for runtime and the Rules "Why?" panel.
@MainActor protocol RuleLifecycleStoring: RulesStore {
    var outcomeEvents: [RuleOutcomeEvent] { get }
    var suppressedRules: [RuleSuppression] { get }
    var ruleActions: [RuleActionRecord] { get }
    func recordSignal(_ outcome: RuleOutcome, source: RuleOutcomeSource, ruleIDs: [String], eventID: String, at: Date) throws
    func recordAction(_ action: RuleActionRecord) throws
    func resolveAction(id: String, state: RuleActionRecord.State, at: Date) throws
    func declineRule(id: String, at: Date) throws
    func noteMatches(ids: [String], at: Date) throws
    func advanceOutcomes(at: Date) throws
    var nextOutcomeBoundary: Date? { get }
}

/// Optional read-state adapter. Absence means unknown, never "unread" for confidence penalties.
@MainActor protocol LearningCardReadState: AnyObject {
    func learningCardWasRead(id: String) -> Bool
}

/// Synchronous post-delete boundary, before a queued network callback can run.
/// Nil IDs means Delete Everything; otherwise only committed removals are reported.
@MainActor protocol JournalDeletionObserving: AnyObject {
    var onJournalDeletion: ((Set<String>?) -> Void)? { get set }
}

/// Retained IDs include read summaries, so consumption cannot look like deletion.
@MainActor protocol LearningDeletionObserving: AnyObject {
    var retainedLearningIDs: Set<String> { get }
    var onLearningDeletion: ((Set<String>) -> Void)? { get set }
}

/// Observable on the concrete writer. Only post-safeguard retained data is exported.
/// `folderURL` is the effective assistant folder (managed wins over the own-agent choice).
@MainActor protocol LearningFolderProviding: AnyObject {
    var folderURL: URL? { get }
    var lastWriteError: String? { get }
    /// Sets the Connect-your-own choice; nil disables that destination. Managed routing takes precedence.
    func setFolder(_ folder: URL?)
    /// Returns only a currently existing exported file; never recreates a Finder-deleted file.
    func fileURL(forJournalItem item: JournalItem) -> URL?
    func dayFolderURL(for date: Date) -> URL?
}

/// Additional explicit user action; ordinary journal deletion never touches Notes/.
@MainActor protocol LearningFolderErasing: AnyObject {
    func deleteFolderContents(includeAssistantNotes: Bool) throws
}

extension LearningFolderProviding {
    func dayFolderURL(for date: Date) -> URL? {
        guard let folderURL else { return nil }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = .current; f.dateFormat = "yyyy-MM-dd"
        let url = folderURL.appendingPathComponent("Zeus/days/" + f.string(from: date))
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue ? url : nil
    }
}
/// Independent mirror hooks: do not replace the runtime's erasure callback.
@MainActor protocol JournalFolderSource: AnyObject {
    var onFolderDeletion: ((Set<String>?) -> Void)? { get set }
    func folderDays() throws -> [Date]
    func folderItems(on day: Date) throws -> [JournalItem]
}
@MainActor protocol LearningHistoryProviding: AnyObject { var allLearnings: [Learning] { get } }
/// Runtime dependency remains optional, including in isolated headless hosts.
@MainActor protocol LearningFolderRecording: LearningFolderProviding {
    func start(learnings: any LearningsProviding)
    func stop()
    func setManagedFolder(_ folder: URL?)
    func recordLearning(_ learning: Learning) async -> [String]
    func recordReflection(id: String, text: Redacted<String>, at: Date) async -> [String]
    func setReflections(_ records: [LearningFolderReflection])
}

struct LearningFolderReflection: Sendable {
    let id: String
    let text: Redacted<String>
    let time: Date
}
