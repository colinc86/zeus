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
    case activity, focus, description, frame, typedText, outcome, reflection
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
protocol JournalStore: Sendable {
    func append(_ item: JournalItem) async throws
    func items(matching query: JournalQuery) async throws -> [JournalItem]
    func delete(_ selection: JournalDeletion) async throws
    func export(matching query: JournalQuery) async throws -> Data
    func prune(retention: JournalRetention, now: Date) async throws
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
    /// 0 = Ask me first, 1 = Just do it. Never bypasses shadow approval or app authority boundaries.
    var autonomy: Double { get set }
    func propose(_ proposals: [RuleProposal], at now: Date) throws -> [LearnedRule]
    func setStatus(_ status: LearnedRuleStatus, id: String, at now: Date) throws
    func edit(id: String, sentence: String, trigger: RuleTrigger, at now: Date) throws
    func delete(id: String) throws
    func recordOutcome(_ outcome: RuleOutcome, ruleIDs: [String], at now: Date) throws
}
