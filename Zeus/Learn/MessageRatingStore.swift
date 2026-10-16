import Foundation
import Observation
import ZeusProtocol

struct RatingDelivery: Codable, Sendable {
    var id: String
    var text: String
    var createdAt: Date
}
/// Local encrypted preference state and transactional outbox. Tests always inject a fixture key.
@MainActor @Observable final class MessageRatingStore: LearningStorageRecovering {
    struct Signal: Codable {
        var id: String
        var label: String
        var created: Date
        var shown: Date?
        var opened: Date?
        var dismissed: Date?
    }
    struct Undo: Codable {
        var id: UUID
        var subject: String
        var version: UUID
        var ratings: [MessageRating]
        var decision: CardMuteDecision?
    }
    struct State: Codable {
        var ratings: [MessageRating] = []
        var decisions: [String: CardMuteDecision] = [:]
        var outbox: [RatingDelivery] = []
        var signals: [String: Signal] = [:]
        var suggested: Set<String> = []
        var dismissedSuggestions: Set<String> = []
        var suggestions: [RatingSuggestion] = []
        var version = UUID()
        var undos: [Undo] = []
    }
    private(set) var state: State
    private(set) var revision: UInt64 = 0
    private(set) var lastError: String?
    private(set) var storageWaitingForUnlock = false
    var pendingStorageWrites: Int { 0 } // User edits fail visibly until saved; no false success.
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var recovery: Task<Void, Never>?
    private var awaitingInitialRead = false
    private let url: URL
    private let key: any JournalKeyProviding
    init(fileURL: URL = ZeusPaths.appSupport.appendingPathComponent("Ratings/ratings.zratings"),
         keyProvider: any JournalKeyProviding = KeychainJournalKeyProvider(account: "ratings-v1")) throws {
        url = fileURL; key = keyProvider
        state = State()
        do { state = try LearningEncryption.read(State.self, at: fileURL, key: keyProvider) ?? State() }
        catch where LearningStorageAvailability.isUnavailable(error) {
            awaitingInitialRead = true; storageWaitingForUnlock = true
            lastError = "Zeus can't open your message preferences right now. It will try again when your Mac unlocks."
            scheduleRecovery()
        }
    }
    isolated deinit { recovery?.cancel() }
    var isReady: Bool { !awaitingInitialRead }
    private func scheduleRecovery() {
        guard recovery == nil else { return }
        recovery = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard let self else { return }; self.recovery = nil; self.retryPendingWrites()
        }
    }
    func retryPendingWrites() {
        guard awaitingInitialRead else { return }
        do {
            state = try LearningEncryption.read(State.self, at: url, key: key) ?? State()
            awaitingInitialRead = false; storageWaitingForUnlock = false; lastError = nil; revision &+= 1; onChange?()
        } catch {
            storageWaitingForUnlock = LearningStorageAvailability.isUnavailable(error)
            if storageWaitingForUnlock { scheduleRecovery() }
            else { lastError = "Zeus couldn't read its message preferences. Existing files were left alone." }
        }
    }
    func commit(_ next: State) throws {
        guard !awaitingInitialRead else { throw LearningStorageError.keyUnavailable }
        do {
            try LearningEncryption.write(next, to: url, key: key)
            state = next; revision &+= 1; lastError = nil; onChange?()
        } catch { lastError = "Zeus couldn't save your message preferences. Your previous preferences are unchanged."; throw error }
    }
    func clear() throws {
        // Erasure must work with a locked keychain, without decrypting or resurrecting old data.
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        recovery?.cancel(); recovery = nil; awaitingInitialRead = false; storageWaitingForUnlock = false
        state = State(); lastError = nil; revision &+= 1; onChange?()
    }
    static func kindKey(_ label: String) -> String {
        label.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }
    static func validateLabel(_ label: String) throws -> String {
        let clean = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...60).contains(clean.count), !clean.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !kindKey(clean).isEmpty else { throw ToolArgumentError("Use a plain kind label of 1–60 characters.") }
        return clean
    }
    static func preferences(_ ratings: [MessageRating]) -> String {
        var parts = ["# What you hear about", "Up: keep telling the user. Need-to-know: use your judgment; send only when useful. Stop: do not send unsolicited messages of this kind, even with a new label or high priority. Replies are unaffected. Generalize the preference, and keep useful preference notes in Notes/."]
        for (value, heading) in [(MessageRatingValue.up, "Up"), (.neutral, "Need-to-know"), (.down, "Stop")] {
            parts.append("## " + heading)
            for rating in ratings.filter({ $0.scope == .kind && $0.rating == value }).sorted(by: { $0.kindKey < $1.kindKey }) {
                parts.append("- \(rating.kindLabel)\n  Example: \(rating.exampleText)")
            }
        }
        return parts.joined(separator: "\n\n")
    }
    func observeCard(_ card: Card) throws {
        guard card.origin == .unprompted, let label = card.about, card.muteDecision == nil, state.signals[card.id] == nil else { return }
        var next = state; next.signals[card.id] = .init(id: card.id, label: label, created: card.createdAt)
        try commit(next)
    }
    func signal(id: String, edge: String, at date: Date) throws {
        guard var signal = state.signals[id] else { return }
        switch edge {
        case "shown": if signal.shown == nil { signal.shown = date }
        case "opened": if signal.opened == nil { signal.opened = date }
        case "dismissed": if signal.dismissed == nil { signal.dismissed = date }
        default: return
        }
        var next = state; next.signals[id] = signal; try commit(next)
    }
    func refreshSuggestions(at now: Date) throws {
        var next = state
        next.signals = next.signals.filter { now.timeIntervalSince($0.value.created) <= 7 * 86400 }
        let eligible = next.signals.values.filter { signal in
            (signal.opened == nil && now.timeIntervalSince(signal.created) >= 86400)
                || (signal.dismissed.flatMap { end in signal.shown.map { end.timeIntervalSince($0) } }.map { $0 >= 0 && $0 <= 3 } == true)
        }
        for (key, group) in Dictionary(grouping: eligible, by: { Self.kindKey($0.label) }) where group.count >= 5 {
            guard !next.suggested.contains(key), !next.ratings.contains(where: { $0.scope == .kind && $0.kindKey == key }),
                  let example = group.max(by: { $0.created < $1.created }) else { continue }
            next.suggested.insert(key)
            next.suggestions.append(.init(id: key, kindLabel: example.label, count: group.count, exampleCardID: example.id))
        }
        if next.signals.count != state.signals.count || next.suggestions.count != state.suggestions.count { try commit(next) }
    }
}
