import Foundation
import ZeusProtocol

/// Explicit user feedback. Neutral means need-to-know, never a local hold.
enum MessageRatingValue: String, Codable, CaseIterable, Sendable { case up, neutral, down }
enum MessageRatingScope: String, Codable, CaseIterable, Sendable { case kind, justThisOne }
struct MessageRating: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var kindLabel: String
    var kindKey: String
    var rating: MessageRatingValue
    var scope: MessageRatingScope
    var exampleCardID: String
    /// Redacted before persistence or delivery.
    var exampleText: String
    var createdAt: Date
    var updatedAt: Date
}
struct RatingSuggestion: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var kindLabel: String
    var count: Int
}
/// Opaque compare-and-swap receipt: undo refuses to overwrite a later edit.
struct MessageRatingUndo: Sendable {
    let id: UUID
}
/// Optional runtime capability; app adapters need not change Shared seams.
/// Mutations redact before committing, throw on failure and return a guarded Undo receipt.
/// Undo is a new preference change/delivery, never recall of an already-sent rating.
@MainActor protocol MessageRatingsProviding: AnyObject {
    var ratings: [MessageRating] { get }
    var mutedToday: [String] { get }
    /// Retained decisions, including prior days. Released decisions remain as evidence.
    var mutedDecisions: [String: CardMuteDecision] { get }
    var ratingSuggestions: [RatingSuggestion] { get }
    var ratingsRevision: UInt64 { get }
    var ratingsError: String? { get }
    func rate(cardID: String, rating: MessageRatingValue, scope: MessageRatingScope, label: String) async throws -> MessageRatingUndo
    func update(id: String, rating: MessageRatingValue, scope: MessageRatingScope, label: String) async throws -> MessageRatingUndo
    func remove(id: String) async throws -> MessageRatingUndo
    func undoRating(_ receipt: MessageRatingUndo) async throws
    /// Releases only this card; does not weaken the kind preference or replay its alert.
    func correctMuted(cardID: String) async throws
    /// Navigation only, not unmute. App wires this callback to reveal the retained cards.
    var onShowMuted: (([String]) -> Void)? { get set }
    func showMuted()
    func dismissRatingSuggestion(id: String) throws
    /// UI reports actual display/read/dismissal edges; fake clocks cover the thresholds.
    func ratingCardShown(id: String)
    func ratingCardOpened(id: String)
    func ratingCardDismissed(id: String)
}
