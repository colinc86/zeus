import Foundation
import ZeusProtocol

/// Optional durability and snapshot reporting alongside the shared CardStoring seam.
/// A failed persistence operation must be returned as a tool error, never success.
@MainActor
protocol CardPersistenceReporting {
    var persistenceError: String? { get }
    var persistedCards: [Card] { get }
}

// Uses CardStore's existing read-only properties; transactional UI publication
// remains CardStore's responsibility (appdev).
extension CardStore: CardPersistenceReporting {
    var persistedCards: [Card] { cards }
}

/// Optional local actions, consumed before the card store persists an agent answer.
@MainActor
protocol LocalCardActionHandling: AnyObject {
    var localActionHandler: ((Card, CardResponse) -> Bool)? { get set }
}

extension CardStore: LocalCardActionHandling {}
