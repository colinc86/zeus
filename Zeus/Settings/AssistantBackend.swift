import Foundation

/// Backend selection supplies a default, while the delivery picker allows an explicit override.
enum AssistantBackend: String, CaseIterable, Identifiable {
    case claude, codex, opencode
    var id: String { rawValue }
    var name: String {
        switch self { case .claude: "Claude Code"; case .codex: "Codex"; case .opencode: "OpenCode" }
    }
    var defaultDeliveryMethod: DeliveryMethod {
        switch self { case .claude: .channel; case .codex: .tmux; case .opencode: .opencode }
    }
}

extension DeliveryMethod {
    var displayName: String {
        switch self { case .channel: "Directly (recommended)"; case .tmux: "Its Terminal pane"; case .opencode: "OpenCode server"; case .polling: "When it checks in" }
    }
    /// One line on what the choice does (D2-7).
    var detail: String {
        switch self {
        case .channel: "Claude Code gets your messages as soon as you send them."
        case .tmux: "Zeus types your messages into the agent's Terminal pane, and waits while you have unsent text there."
        case .opencode: "Zeus sends your messages to OpenCode's local server."
        case .polling: "Your messages wait until the agent checks in with Zeus."
        }
    }
}
