import Foundation

// LM2 Phase A integration seams. Platform-owned until the PM promotes them to CONTRACT §13.

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

/// On-device only. The same pipeline covers every payload string before JournalStore.append.
protocol Redactor: Sendable {
    func redact(_ text: String) async -> Redacted<String>
    func redact(_ payload: JournalPayload) async -> Redacted<JournalPayload>
}
extension Redactor {
    func redact(_ payload: JournalPayload) async -> Redacted<JournalPayload> {
        let description = await redact(payload.description)
        let text = await payload.text.asyncMap { await redact($0) }
        var details: [String: String] = [:]
        var report = description.report
        func merge(_ other: RedactionReport) {
            for (kind, count) in other.counts { report.counts[kind, default: 0] += count }
            if other.semanticEngine == .onDeviceModel { report.semanticEngine = .onDeviceModel }
            else if report.semanticEngine == .patternsOnly { report.semanticEngine = other.semanticEngine }
        }
        if let text { merge(text.report) }
        // Keys can contain captured text too; redact both halves. Collisions retain no raw value.
        for key in payload.details.keys.sorted() {
            let safeKey = await redact(key), safeValue = await redact(payload.details[key] ?? "")
            details[safeKey.value] = safeValue.value; merge(safeKey.report); merge(safeValue.report)
        }
        return .init(.init(description: description.value, text: text?.value, details: details), report: report)
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
/// Phase A stores text only. Frames require the Phase B image-redaction path; .frame is reserved and rejected for now.
struct JournalPayload: Codable, Equatable, Sendable {
    var description: String
    var text: String?
    var details: [String: String]
    init(description: String, text: String? = nil, details: [String: String] = [:]) {
        self.description = description; self.text = text; self.details = details
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

struct RuleTimeWindow: Codable, Equatable, Sendable {
    /// Local minutes after midnight, 0..<1440; a wrapping range crosses midnight.
    var startMinute: Int
    var endMinute: Int
    /// Calendar weekdays 1...7; empty means every day.
    var weekdays: Set<Int> = []
}
struct RuleTrigger: Codable, Equatable, Sendable {
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
}
enum RuleOutcome: String, Codable, Sendable { case accepted, skipped, undone, ignored, toggledOff, toggledOn, edited }
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
}
/// App-owned adapter to CardStore.recordNotice; these lines NEVER peek, badge or play a sound.
@MainActor protocol LearningNoticeRecording: AnyObject {
    /// Repeated IDs reconnect the action after relaunch without duplicating the persisted line.
    @discardableResult func recordLearningNotice(_ notice: LearningNotice, action: (@MainActor () -> Void)?) -> Bool
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
}
