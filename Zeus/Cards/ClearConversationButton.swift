import SwiftUI

enum ConversationHistoryCopy {
    static let preservation = "Clearing removes read messages and completed history. Unread messages, open questions and actions, and unsent or unconfirmed messages are kept."
    static let confirmation = preservation + " Messages already on their way are still delivered."
}

struct ClearConversationButton: View {
    let cards: CardStore
    @State private var confirming = false
    var body: some View {
        Button("Clear Conversation…", role: .destructive) { confirming = true }.accessibilityLabel("Clear Conversation")
            .alert("Clear the conversation?", isPresented: $confirming) {
                Button("Clear", role: .destructive) { _ = cards.clearConversation() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(ConversationHistoryCopy.confirmation)
            }
    }
}
