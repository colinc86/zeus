import Foundation
import ZeusProtocol

/// App-owned onboarding actions are handled locally, without creating an agent reply.
enum WelcomeCard {
    static let id = "c_welcome1"
    static let agentSettingsURL = URL(string: "zeus://settings/agent")
    static func make(now: Date = Date()) -> Card {
        Card(id: id, kind: .message, title: "Welcome to Zeus",
             body: "Zeus is the face of your AI assistant: it shows you its messages, asks you its questions and hands you finished work.\n\nConnect your assistant with the button below to start. Click Zeus to talk, drag it anywhere, and right-click for more.",
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
