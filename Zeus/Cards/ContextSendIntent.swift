import Foundation
import ZeusProtocol

struct ContextDraftItem: Identifiable, Equatable {
    enum Kind: String, Sendable { case window = "Window", selection = "Selection", page = "Page", picture = "Picture" }
    let attachment: Attachment
    let kind: Kind
    /// Already redacted; safe for the local hover preview. Pictures use the covered image's private file.
    let preview: String
    var id: String { attachment.id }
}
struct ContextDraftResult {
    var items: [ContextDraftItem] = []
    var caption: String
    static let explanation = "From the window in front, with private details removed. Remove anything you don't want to send."
    static let unavailable = "Turn on Windows and pages or Screen in Settings › Privacy to attach what's in front."
    static let privateCaption = "Some things weren't attached because they're private."
}

/// App-local, already-redacted attachment intent is saved in the same history transaction as Send.
struct ContextSendIntent: Codable, Equatable {
    let cardID: String
    let body: String
    let kinds: [String]
    var receipt: Receipt?
    struct Receipt: Codable, Equatable {
        let deliveredAt: Date
        let agent: String
        let sessionLabel: String
        let sessionID: String
        init(_ value: LearningContextDeliveryReceipt) {
            deliveredAt = value.deliveredAt; agent = value.agent; sessionLabel = value.sessionLabel; sessionID = value.sessionID
        }
    }
    init?(cardID: String, body: String, items: [ContextDraftItem]) {
        guard !items.isEmpty else { return nil }
        self.cardID = cardID; self.body = body
        kinds = [ContextDraftItem.Kind.window, .selection, .page, .picture].filter { kind in items.contains { $0.kind == kind } }.map(\.rawValue)
    }
}

extension CardStore: LearningContextReceiptRecording {
    func recordLearningContextReceipt(_ receipt: LearningContextDeliveryReceipt) {
        acceptContextReceipt(receipt)
    }
}
