import Foundation
import Observation

/// The digests and moments Zeus made for the assistant (CONTRACT §13), kept one year in `learnings.json` (0600) next to
/// the raw events. The runtime reads it through `LearningsProviding`; it never sees raw events.
@MainActor
@Observable
final class LearningsStore: LearningsProviding, LearningReadRecording, LearningDeletionObserving {
    static let fileName = "learnings.json"
    static let keepDays = 365

    private struct State: Codable {
        var learnings: [Learning] = []
        var lastReadID: String?
        var readIDs: Set<String>?
        var lastReadAt: Date?
        /// Days (`yyyy-mm-dd`) already summarized, so each digest is made once.
        var digestedDays: Set<String> = []
        /// The moment kinds sent per day, for the four-a-day limit.
        var momentsByDay: [String: [MomentKind]] = [:]
    }

    private var state: State
    @ObservationIgnored private let files: ActivityStore
    @ObservationIgnored private let isEnabled: () -> Bool
    /// Set by the runtime; called whenever a new learning is stored.
    @ObservationIgnored var onNewLearning: ((Learning) -> Void)?
    /// Set by the app: adds the quiet "Sent your daily summary · View" line.
    @ObservationIgnored var onRecorded: ((Learning) -> Void)?
    /// The last write failed; Settings shows it.
    private(set) var saveError: String?

    init(files: ActivityStore, isEnabled: @escaping () -> Bool) {
        self.files = files
        self.isEnabled = isEnabled
        state = files.read(named: Self.fileName).flatMap { try? ActivityStore.decoder.decode(State.self, from: $0) } ?? State()
    }

    @ObservationIgnored var onLearningDeletion: ((Set<String>) -> Void)?
    var retainedLearningIDs: Set<String> { Set(state.learnings.map(\.id)) }

    var learnings: [Learning] { state.learnings }
    var learningsEnabled: Bool { isEnabled() }

    func unreadLearnings() -> [Learning] {
        guard isEnabled() else { return [] }
        if let id = state.lastReadID, let index = state.learnings.firstIndex(where: { $0.id == id }) {
            return Array(state.learnings[(index + 1)...]).filter { !(state.readIDs ?? []).contains($0.id) }
        }
        if let date = state.lastReadAt { return state.learnings.filter { $0.createdAt > date && !(state.readIDs ?? []).contains($0.id) } }
        return state.learnings.filter { !(state.readIDs ?? []).contains($0.id) }
    }

    func markLearningRead(id: String) {
        state.readIDs = (state.readIDs ?? []).union([id]); save()
    }

    func markLearningsRead(through id: String) {
        guard let learning = state.learnings.first(where: { $0.id == id }) else { return }
        if let current = state.lastReadID, let old = state.learnings.firstIndex(where: { $0.id == current }),
           let new = state.learnings.firstIndex(where: { $0.id == id }), new <= old { return }
        state.lastReadID = id
        state.lastReadAt = learning.createdAt
        save()
    }

    func isDigested(_ dayKey: String) -> Bool { state.digestedDays.contains(dayKey) }
    func markDigested(_ dayKeys: [String]) { state.digestedDays.formUnion(dayKeys); save() }
    func momentsSent(on dayKey: String) -> [MomentKind] { state.momentsByDay[dayKey] ?? [] }

    /// Stores a learning, then tells the thread and the runtime.
    func add(_ kind: Learning.Kind, text: String, at date: Date, moment: MomentKind? = nil, dayKey: String? = nil) {
        let learning = Learning(id: "l_" + UUID().uuidString.prefix(8).lowercased(), kind: kind, createdAt: date, text: text)
        state.learnings.append(learning)
        if let moment, let dayKey { state.momentsByDay[dayKey, default: []].append(moment) }
        save()
        onRecorded?(learning)
        onNewLearning?(learning)
    }

    /// Drops learnings older than a year, and the bookkeeping for days that old.
    func prune(now: Date, calendar: Calendar) {
        guard let cutoff = calendar.date(byAdding: .day, value: -Self.keepDays, to: calendar.startOfDay(for: now)) else { return }
        let cutoffKey = files.dayKey(cutoff)
        let retainedBefore = retainedLearningIDs
        let before = state.learnings.count
        state.learnings.removeAll { $0.createdAt < cutoff }
        let oldDays = state.digestedDays.filter { $0 < cutoffKey }
        let oldMoments = state.momentsByDay.keys.filter { $0 < cutoffKey }
        guard before != state.learnings.count || !oldDays.isEmpty || !oldMoments.isEmpty else { return }
        onLearningDeletion?(retainedBefore.subtracting(retainedLearningIDs))
        state.digestedDays.subtract(oldDays)
        for key in oldMoments { state.momentsByDay.removeValue(forKey: key) }
        save()
    }

    /// Forgets everything (the file itself is removed with the rest of the Activity folder).
    func reset() {
        let removed = retainedLearningIDs
        state = State()
        onLearningDeletion?(removed)
        saveError = nil
    }

    private func save() {
        do {
            try files.writePrivate(ActivityStore.encoder.encode(state), named: Self.fileName)
            saveError = nil
        } catch { saveError = "Zeus couldn't save its summaries. \(error.localizedDescription)" }
    }
}
