import Foundation
import Observation

/// Privacy reads the store's redacted values verbatim. Filters apply to the timeline, export and sent ledger alike.
@MainActor @Observable
final class JournalViewerModel {
    @ObservationIgnored let journal: any JournalStore
    let pictures: JournalPictureModel
    private(set) var timeline: [JournalTimelineRow] = []
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored var beforeDelete: () -> Void = {}
    var day: Date { didSet { reload() } }
    var level = 0 { didSet { reload() } }
    var app = "" { didSet { reload() } }
    var search = "" { didSet { reload() } }
    var sentOnly = false { didSet { if sentOnly { level = 0; app = "" }; reload() } }
    private(set) var items: [JournalItem] = []
    private(set) var applications: [String] = []
    private(set) var error: String?
    private var observing = true
    private(set) var deletedItem: JournalItem?
    @ObservationIgnored private var undoExpiry: Task<Void, Never>?
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private var undoDeadline: Date?

    init(journal: any JournalStore, calendar: Calendar = .current, now: Date = Date(), clock: @escaping () -> Date = Date.init) {
        self.journal = journal; pictures = JournalPictureModel(journal: journal, clock: clock); self.calendar = calendar; self.clock = clock; day = now
        pictures.beforeDelete = { [weak self] in self?.beforeDelete(); self?.forgetUndo() }
        pictures.didChange = { [weak self] in self?.reload() }
        reload(); observe()
    }
    var query: JournalQuery {
        var query = JournalQuery()
        query.from = calendar.startOfDay(for: day)
        query.to = calendar.date(byAdding: .day, value: 1, to: query.from ?? day)
        if let level = JournalLevel(rawValue: level) { query.levels = [level] }
        if !app.isEmpty { query.apps = [app] }
        if sentOnly { query.kinds = [.sentToAssistant] }
        else { query.kinds = Set(JournalKind.allCases.filter { $0 != .sentToAssistant }) }
        query.text = search
        query.limit = 100_000
        return query
    }
    func reload() {
        do {
            items = try journal.items(matching: query).sorted { $0.time == $1.time ? $0.id < $1.id : $0.time > $1.time }
            var all = query; all.apps = []; all.levels = []; all.text = ""
            applications = Array(Set(try journal.items(matching: all).compactMap(\.app))).sorted()
            var catalogQuery = query; catalogQuery.text = ""
            timeline = JournalTimelineRow.grouped(items, catalog: try journal.items(matching: catalogQuery), calendar: calendar)
            pictures.update(timeline)
            error = nil
        } catch { self.error = "Couldn't read the journal. Nothing was deleted."; items = []; timeline = []; pictures.update([]) }
    }
    @discardableResult func delete(_ selection: JournalDeletion) -> Bool {
        beforeDelete(); forgetUndo()
        do { try journal.delete(selection); reload(); return true }
        catch { self.error = "Couldn't delete these records. Try again."; return false }
    }
    func deleteItem(_ item: JournalItem) {
        guard item.kind != .sentToAssistant, delete(.item(item.id)) else { return }
        deletedItem = item; undoDeadline = clock().addingTimeInterval(5)
        undoExpiry = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            self?.forgetUndo()
        }
    }
    func undoDelete() {
        guard let item = deletedItem, let deadline = undoDeadline, clock() < deadline else { forgetUndo(); return }
        do { try journal.append(item); forgetUndo(); reload() }
        catch { self.error = "Couldn't restore this record. Try again." }
    }
    func forgetUndo() { pictures.forgetUndo(); undoExpiry?.cancel(); undoExpiry = nil; undoDeadline = nil; deletedItem = nil }

    func export() -> Data? {
        do { let data = try journal.export(matching: query); error = nil; return data }
        catch { self.error = "Couldn't export these records."; return nil }
    }
    func evidence(ids: [String]) -> [JournalItem] {
        var query = JournalQuery(); query.limit = 100_000
        let wanted = Set(ids)
        do { return try journal.items(matching: query).filter { wanted.contains($0.id) }.sorted { $0.time < $1.time } }
        catch { self.error = "Couldn't read the evidence."; return [] }
    }
    private func observe() {
        guard observing else { return }
        withObservationTracking { _ = journal.revision; _ = journal.lastError } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.reload(); self?.observe() }
        }
    }
}
