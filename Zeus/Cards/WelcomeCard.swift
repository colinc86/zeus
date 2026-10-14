import Foundation
import ZeusProtocol

/// App-owned onboarding actions are handled locally, without creating an agent reply.
enum WelcomeCard {
    static let id = "c_welcome1"
    static let agentSettingsURL = URL(string: "zeus://settings/agent")
    /// First-run copy (D19): connect, the status strip, and the assistant's control of Zeus. No longer than 0.1.7's
    /// 237 characters.
    static let body = "Zeus is the face of your AI assistant. Connect it below, then click Zeus to talk.\n\nThe line under the messages tells you what Zeus is waiting on.\n\nYour assistant can change Zeus when you ask (on by default; switch in Settings\u{00A0}›\u{00A0}General)."
    static let lengthBudget = 237
    static func make(now: Date = Date()) -> Card {
        Card(id: id, kind: .message, title: "Welcome to Zeus",
             body: Self.body,
             priority: .high, createdAt: now, updatedAt: now)
    }
    @MainActor @discardableResult
    static func installIfNeeded(cards: CardStore, settings: AppSettings, now: Date = Date()) -> Bool {
        guard !settings.hasShownWelcome else { return false }
        let isNew = cards.card(id: id) == nil
        if isNew { cards.add(make(now: now)) }
        settings.hasShownWelcome = true
        return isNew
    }
}
