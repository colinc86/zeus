import Foundation

/// Settings → Assistant wording for Connect your own that the app and docs/SETUP.md share.
public enum ZeusSettingsCopy {
    /// The Assistant session picker's Auto choice (A4N-2). Auto isn't simply "newest": among connected sessions of
    /// the chosen agent it takes the newest one Zeus can message directly (a Claude Code channel), else the newest.
    public enum Auto {
        /// The Auto item and field text. Names the session Auto picks right now, when there is one.
        /// - Parameter current: the session label Auto resolves to ("Claude · Website"), or `nil`.
        public static func title(current: String?) -> String {
            guard let current, !current.isEmpty else { return "Auto" }
            return "Auto (\(current))"
        }

        /// The caption under the picker, saying how Auto chooses.
        /// - Parameters:
        ///   - agent: the chosen agent's name ("Claude Code", "Codex", "OpenCode").
        ///   - prefersDirect: whether that agent can take messages directly (Claude Code's channel).
        public static func explanation(agent: String, prefersDirect: Bool) -> String {
            prefersDirect
                ? "Auto picks your newest \(agent) session that Zeus can message directly, or else your newest \(agent) session."
                : "Auto picks your newest \(agent) session."
        }
    }

    /// The Terminal pane picker's prompt. Use it as the picker's placeholder, never as a menu item (A4D-11).
    public static let choosePanePlaceholder = "Choose a pane"
}
