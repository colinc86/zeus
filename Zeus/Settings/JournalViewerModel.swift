import Foundation
import Observation

/// Privacy reads the store's redacted values verbatim. Filters apply to the timeline, export and sent ledger alike.
@MainActor @Observable
final class JournalViewerModel {
    @ObservationIgnored let journal: any JournalStore
    @ObservationIgnored var learningEnabled: () -> Bool = { true }
    /// The morning brief request goes even with every level off (UX5); the empty caption says so.
    @ObservationIgnored var briefEnabled: () -> Bool = { false }
    static let emptyNothingPrepared = "Nothing yet. Zeus sends a morning summary, notes during the day and an evening reflection."
    static let emptyLearningOff = "Nothing yet. Learn from me is off, so Zeus has nothing to send."
    static let emptyLearningOffBriefOn = "Nothing yet. Learn from me is off. Zeus still asks for a morning brief; see Settings › Assistant."
    private(set) var hasReceivedItems = false
    var emptyCaption: String {
        if !search.isEmpty || (!sentOnly && (level != 0 || !app.isEmpty)) { return "Nothing matches." }
        if !sentOnly { return "Nothing kept on this day." }
        if hasReceivedItems || deliveries?.pending.isEmpty == false || deliveries?.discarded.isEmpty == false { return "Nothing received on this day." }
        if learningEnabled() { return Self.emptyNothingPrepared }
        return briefEnabled() ? Self.emptyLearningOffBriefOn : Self.emptyLearningOff
    }
    var activeFolder: LearningFolderModel? { folder?.folderURL == nil ? nil : folder }
    var folder: LearningFolderModel?
    var deliveries: LearningDeliveryModel?
    var waiting: [PendingLearningDelivery] {
        guard sentOnly else { return [] }
        return (deliveries?.pending ?? []).filter { search.isEmpty || $0.text.localizedCaseInsensitiveContains(search) }
            .sorted { $0.preparedAt == $1.preparedAt ? $0.id < $1.id : $0.preparedAt > $1.preparedAt }
    }
    var notSent: [DiscardedLearningDelivery] {
        guard sentOnly else { return [] }
        return (deliveries?.discarded ?? []).filter {
            search.isEmpty || $0.text.localizedCaseInsensitiveContains(search) || $0.queueReason.localizedCaseInsensitiveContains(search)
        }.sorted { $0.discardedAt == $1.discardedAt ? $0.id < $1.id : $0.discardedAt > $1.discardedAt }
    }
    let pictures: JournalPictureModel
    private(set) var timeline: [JournalTimelineRow] = []
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored var beforeDelete: () -> Void = {}
    var day: Date { didSet { filtersChanged() } }
    var level = 0 { didSet { filtersChanged() } }
    var app = "" { didSet { filtersChanged() } }
    var search = "" { didSet { filtersChanged() } }
    var sentOnly = false { didSet { if sentOnly { level = 0; app = "" }; filtersChanged() } }
    private(set) var selectedAnswerID: String?
    private(set) var answerSelectionRevision: UInt64 = 0
    @ObservationIgnored private var pendingAnswerID: String?
    func showAnswer(id: String) {
        pendingAnswerID = id
        if let snapshot, snapshot.revision == journal.revision,
           snapshot.expiresAt.map({ $0 > clock() }) ?? true { selectPendingAnswer(snapshot) }
        else if loadTask == nil { reload() }
    }
    private func selectPendingAnswer(_ snapshot: JournalSnapshot) {
        guard let id = pendingAnswerID else { return }
        pendingAnswerID = nil
        guard let answer = snapshot.items.first(where: { $0.kind == .sentToAssistant && $0.id == id }) else {
            error = "This journal answer is no longer kept."; return
        }
        search = ""; sentOnly = true; day = answer.time; selectedAnswerID = id; answerSelectionRevision &+= 1
    }
    private(set) var items: [JournalItem] = []
    private(set) var applications: [String] = []
    private(set) var error: String?
    private var observing = true
    private(set) var deletedItem: JournalItem?
    private(set) var deletedTyping: TypingDeletionReceipt?
    @ObservationIgnored private var undoExpiry: Task<Void, Never>?
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private var undoDeadline: Date?

    init(journal: any JournalStore, calendar: Calendar = .current, now: Date = Date(), clock: @escaping () -> Date = Date.init) {
        self.journal = journal; pictures = JournalPictureModel(journal: journal, clock: clock); self.calendar = calendar; self.clock = clock; day = now
        pictures.beforeDelete = { [weak self] in self?.beforeDelete(); self?.forgetUndo() }
        pictures.didChange = { [weak self] in self?.reload() }
        reload(); observe()
    }
    isolated deinit { loadTask?.cancel(); expiryTask?.cancel(); undoExpiry?.cancel() }

    /// Ask the writer for its existing day directory, preserving its calendar and missing-file policy.
    var dayFolderURL: URL? { folder?.provider?.dayFolderURL(for: day) }
    func showDayInFinder() { if let url = dayFolderURL { folder?.reveal(url) } }
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
    private(set) var isLoading = false
    @ObservationIgnored private var snapshot: JournalSnapshot?
    @ObservationIgnored private var searchIndex: [String: String] = [:]
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var loadID = UUID()
    @ObservationIgnored private var expiryTask: Task<Void, Never>?

    /// Explicit refresh revalidates access and retries pictures, even if the revision is unchanged.
    func reload() {
        pictures.retryReads()
        loadTask?.cancel(); loadTask = nil; expiryTask?.cancel(); expiryTask = nil
        let id = UUID(); loadID = id
        snapshot = nil; searchIndex = [:]
        if let source = journal as? any JournalSnapshotProviding {
            isLoading = true; items = []; timeline = []; pictures.update([])
            loadTask = Task { @MainActor [weak self] in
                do {
                    let value = try await source.journalSnapshot()
                    guard let self, self.loadID == id, !Task.isCancelled else { return }
                    self.loadTask = nil
                    guard value.revision == self.journal.revision,
                          value.expiresAt.map({ $0 > self.clock() }) ?? true else { self.reload(); return }
                    self.accept(value)
                } catch {
                    guard let self, self.loadID == id, !Task.isCancelled else { return }
                    self.loadTask = nil; self.readFailed()
                }
            }
        } else {
            // In-memory/legacy adapters still get one query, not four queries per filter edit.
            do {
                var all = JournalQuery(); all.limit = 100_000
                let values = try journal.items(matching: all)
                accept(.init(revision: journal.revision, items: values, expiresAt: nil))
            } catch { readFailed() }
        }
    }
    private func readFailed() {
        isLoading = false; snapshot = nil; searchIndex = [:]
        error = "Couldn't read the journal. Nothing was deleted."
        items = []; timeline = []; applications = []; hasReceivedItems = false; pictures.update([])
    }
    private func accept(_ value: JournalSnapshot) {
        snapshot = value
        searchIndex = Dictionary(value.items.map { item in
            (item.id, (item.payload.value.description + "\n" + (item.payload.value.topic ?? "") + "\n" + (item.payload.value.text ?? ""))
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current))
        }, uniquingKeysWith: { _, last in last })
        hasReceivedItems = value.items.contains { $0.kind == .sentToAssistant }
        isLoading = false; error = nil; applyFilters(value); selectPendingAnswer(value)
        if let expiry = value.expiresAt {
            let delay = max(0, expiry.timeIntervalSince(clock()))
            expiryTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                self?.reload()
            }
        }
    }
    private func filtersChanged() {
        guard let snapshot, snapshot.revision == journal.revision,
              snapshot.expiresAt.map({ $0 > clock() }) ?? true else {
            if loadTask == nil { reload() }
            return
        }
        applyFilters(snapshot)
    }
    private func applyFilters(_ snapshot: JournalSnapshot) {
        let q = query
        let dayItems = snapshot.items.filter { item in
            (q.from.map { item.time >= $0 } ?? true) && (q.to.map { item.time < $0 } ?? true)
                && q.kinds.contains(item.kind)
        }
        applications = Array(Set(dayItems.compactMap(\.app))).sorted()
        let catalog = dayItems.filter { item in
            (q.levels.isEmpty || q.levels.contains(item.level)) && (q.apps.isEmpty || q.apps.contains(item.app ?? ""))
        }
        let needle = search.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        items = catalog.filter { needle.isEmpty || (searchIndex[$0.id] ?? "").contains(needle) }
            .sorted { $0.time == $1.time ? $0.id < $1.id : $0.time > $1.time }
        timeline = JournalTimelineRow.grouped(items, catalog: catalog, calendar: calendar)
        pictures.update(timeline)
    }
    /// Tests and explicit navigation may await the current load without starting a second scan.
    func waitForLoad() async {
        while let task = loadTask { await task.value }
    }

    @discardableResult func delete(_ selection: JournalDeletion) -> Bool {
        beforeDelete(); forgetUndo()
        do { try journal.delete(selection); reload(); return true }
        catch { self.error = "Couldn't delete these records. Try again."; return false }
    }
    func deleteItem(_ item: JournalItem) {
        if item.level == .typed && item.kind == .typedText { _ = deleteTyping(ids: [item.id]); return }
        guard item.kind != .sentToAssistant, delete(.item(item.id)) else { return }
        deletedItem = item; undoDeadline = clock().addingTimeInterval(5)
        undoExpiry = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            self?.forgetUndo()
        }
    }
    func undoDelete() {
        if let receipt = deletedTyping {
            guard let deadline = undoDeadline, clock() < deadline else { forgetUndo(); return }
            do {
                guard let store = journal as? any TypingJournalStoring else { throw TypingJournalError.unsupported }
                try store.restoreTyping(receipt); forgetUndo(); reload()
            } catch { self.error = "Couldn't restore this typing. It may have changed or expired." }
            return
        }
        guard let item = deletedItem, let deadline = undoDeadline, clock() < deadline else { forgetUndo(); return }
        do { try journal.append(item); forgetUndo(); reload() }
        catch { self.error = "Couldn't restore this record. Try again." }
    }
    @discardableResult func deleteTyping(ids: Set<String>) -> Bool {
        beforeDelete(); forgetUndo()
        do {
            guard let store = journal as? any TypingJournalStoring else { throw TypingJournalError.unsupported }
            deletedTyping = try store.deleteTyping(ids: ids); undoDeadline = clock().addingTimeInterval(5)
            undoExpiry = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(5)) } catch { return }; self?.forgetUndo()
            }
            reload(); return true
        } catch { self.error = "Couldn't delete this typing. Nothing was deleted."; return false }
    }
    /// A group action names the entire app/hour, including stretches hidden by the current text search.
    @discardableResult func deleteTypingGroup(_ group: JournalTypingGroup) -> Bool {
        var query = JournalQuery(); query.from = group.hour; query.to = group.end
        query.apps = [group.app]; query.levels = [.typed]; query.kinds = [.typedText]; query.limit = 100_000
        do { return deleteTyping(ids: Set(try journal.items(matching: query).map(\.id))) }
        catch { self.error = "Couldn't delete this typing. Nothing was deleted."; return false }
    }
    func forgetUndo() { pictures.forgetUndo(); undoExpiry?.cancel(); undoExpiry = nil; undoDeadline = nil; deletedItem = nil; deletedTyping = nil }

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
