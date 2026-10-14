import Foundation
import ZeusProtocol

/// A write-ahead response intent closes the gap between the card snapshot and
/// delivery ledger. IDs are allocated before displaying a response-capable card.
@MainActor
final class ResponseJournal {
    struct Intent: Codable, Equatable {
        let cardID: String
        let deliveryID: String
    }
    private let location: URL
    private(set) var intents: [Intent]
    init(location: URL) throws {
        self.location = location
        intents = FileManager.default.fileExists(atPath: location.path)
            ? try ZeusJSON.decoder().decode([Intent].self, from: Data(contentsOf: location)) : []
        guard Set(intents.map(\.cardID)).count == intents.count, Set(intents.map(\.deliveryID)).count == intents.count else { throw DeliveryLedgerError.invalidSnapshot }
    }
    func prepare(_ cardID: String) throws {
        guard !intents.contains(where: { $0.cardID == cardID }) else { return }
        var id = Delivery(kind: .reply, sessionKey: "", content: "").id
        while intents.contains(where: { $0.deliveryID == id }) { id = Delivery(kind: .reply, sessionKey: "", content: "").id }
        try save(intents + [Intent(cardID: cardID, deliveryID: id)])
    }
    func complete(_ cardID: String) throws { try save(intents.filter { $0.cardID != cardID }) }
    private func save(_ next: [Intent]) throws {
        guard next != intents else { return }
        try ZeusJSON.encoder().encode(next).write(to: location, options: .atomic)
        intents = next
    }
}
