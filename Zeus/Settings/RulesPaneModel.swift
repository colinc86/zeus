import Foundation
import Observation

/// User edits stay on the same rule and retain its evidence. External actions remain shadow until explicit approval.
@MainActor @Observable
final class RulesPaneModel {
    @ObservationIgnored let store: any RulesStore
    @ObservationIgnored let journal: JournalViewerModel
    @ObservationIgnored private let clock: () -> Date
    var selectedRuleID: String?
    var editingID: String?
    var sentence = ""
    var appIDs = ""
    var state = ""
    var startMinute = ""
    var endMinute = ""
    var kind = LearnedRuleKind.passive
    var weekdays: Set<Int> = []
    private(set) var deletedRule: LearnedRule?
    @ObservationIgnored private var undoExpiry: Task<Void, Never>?
    @ObservationIgnored private var undoDeadline: Date?
    private(set) var error: String?
    init(store: any RulesStore, journal: JournalViewerModel, clock: @escaping () -> Date = Date.init) {
        self.store = store; self.journal = journal; self.clock = clock
    }
    var rules: [LearnedRule] { store.rules }
    var autonomy: Double {
        get { store.autonomy }
        set { store.autonomy = min(1, max(0, newValue)); error = store.lastError }
    }
    var selected: LearnedRule? { rules.first { $0.id == selectedRuleID } }
    func beginEdit(_ rule: LearnedRule?) {
        editingID = rule?.id; sentence = rule?.sentence ?? ""; kind = rule?.kind ?? .passive
        appIDs = rule?.trigger.apps.sorted().joined(separator: ", ") ?? ""
        state = rule?.trigger.state ?? ""
        startMinute = rule?.trigger.time.map { Self.clockText($0.startMinute) } ?? ""
        endMinute = rule?.trigger.time.map { Self.clockText($0.endMinute) } ?? ""
        weekdays = rule?.trigger.time?.weekdays ?? []
        error = nil
    }
    @discardableResult func save() -> Bool {
        let text = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { error = "Write a rule first."; return false }
        var trigger = editingID.flatMap { id in rules.first { $0.id == id }?.trigger } ?? RuleTrigger()
        trigger.apps = Set(appIDs.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        trigger.state = state.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : state.trimmingCharacters(in: .whitespacesAndNewlines)
        if !startMinute.isEmpty || !endMinute.isEmpty {
            guard let start = Self.minute(startMinute), let end = Self.minute(endMinute) else {
                error = "Enter a start and end time as HH:mm."; return false
            }
            trigger.time = RuleTimeWindow(startMinute: start, endMinute: end, weekdays: weekdays)
        } else { trigger.time = weekdays.isEmpty ? nil : RuleTimeWindow(startMinute: 0, endMinute: 0, weekdays: weekdays) }
        return mutate {
            if let id = editingID { try store.edit(id: id, sentence: text, trigger: trigger, at: clock()) }
            else { _ = try store.addOwn(RuleProposal(sentence: text, trigger: trigger, kind: .passive), at: clock()) }
        }
    }
    func setEnabled(_ enabled: Bool, rule: LearnedRule) {
        _ = mutate {
            try store.setStatus(enabled ? .active : .retired, id: rule.id, at: clock())
        }
    }
    func approve(_ rule: LearnedRule) { setEnabled(true, rule: rule) }
    func delete(_ rule: LearnedRule) {
        guard mutate({ try store.delete(id: rule.id) }) else { return }
        undoExpiry?.cancel(); deletedRule = rule; undoDeadline = clock().addingTimeInterval(5)
        undoExpiry = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            self?.deletedRule = nil; self?.undoDeadline = nil
        }
    }
    func undoDelete() {
        guard let rule = deletedRule, let deadline = undoDeadline, clock() < deadline else { deletedRule = nil; return }
        if mutate({ try store.restoreDeleted(rule) }) { undoExpiry?.cancel(); deletedRule = nil; undoDeadline = nil }
    }
    func dismiss(_ rule: LearnedRule) { _ = mutate { try store.setStatus(.proposed, id: rule.id, at: clock()) } }
    private func mutate(_ action: () throws -> Void) -> Bool {
        do { try action(); error = nil; return true }
        catch { self.error = "Couldn't save this rule. Try again."; return false }
    }
    static func triggerText(_ trigger: RuleTrigger, appName: (String) -> String = { $0 }) -> String {
        var pieces: [String] = []
        if let time = trigger.time {
            let days = time.weekdays.sorted().map { Calendar.current.weekdaySymbols[max(0, min(6, $0 - 1))] }.joined(separator: ", ")
            pieces.append((time.startMinute == time.endMinute ? "All day" : "\(clockText(time.startMinute))–\(clockText(time.endMinute))") + (days.isEmpty ? " every day" : " on " + days))
        }
        if !trigger.apps.isEmpty { pieces.append("in " + trigger.apps.sorted().map(appName).joined(separator: ", ")) }
        if let state = trigger.state { pieces.append("when " + state) }
        return pieces.isEmpty ? "Any time" : pieces.joined(separator: "; ")
    }
    private static func clockText(_ minute: Int) -> String { String(format: "%02d:%02d", minute / 60, minute % 60) }
    private static func minute(_ text: String) -> Int? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]), (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return hour * 60 + minute
    }
}
