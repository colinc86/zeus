import Foundation

// A4D-10: what Zeus says when delivery or the assistant it runs goes wrong. The runtime maps each of its error cases
// to one of these instead of showing tmux, HTTP or protocol text. Each line says what happened in plain words, then
// what happens next or what to do. See docs/design/CONVERSATION.md §3 and MANAGED.md §3.

/// Plain copy for runtime failures: delivery captions under a message, OpenCode notices in Settings, and the managed
/// assistant's status detail.
public enum ZeusRuntimeCopy {
    /// Captions under a saved message that hasn't reached the assistant yet. Zeus keeps the message, so each line
    /// says whether Zeus tries again by itself or what the user should change.
    public enum Delivery {
        /// tmux isn't installed (Terminal-pane delivery).
        public static let missingTmux = "Zeus can't find tmux. Install it (brew install tmux) and Zeus sends this saved message."
        /// No Terminal pane is chosen for Terminal-pane delivery.
        public static let missingPane = "Choose your assistant's Terminal pane in Settings → Assistant. Zeus sends this once it's set."
        /// Zeus couldn't set up the files it uses to talk to tmux.
        public static let couldNotPrepare = "Zeus couldn't get this message ready for Terminal. It will try again."
        /// tmux didn't answer in time.
        public static let terminalTimedOut = "Terminal didn't respond in time. Zeus will try again."
        /// A tmux command failed. The exit status belongs in a log, not in the caption.
        public static let terminalFailed = "Zeus couldn't type into your assistant's Terminal pane. It will try again."
        /// The pane has a draft the user hasn't sent.
        public static let terminalBusy = "Your assistant's Terminal has unsent text. Zeus sends this once it's clear."
        /// The message is taller than the visible pane, so Zeus can't check what it typed.
        public static let terminalTooSmall = "This message is too long to check in the Terminal pane. Make the pane bigger, or ask your assistant to check Zeus for messages."
        /// Someone typed in the pane while Zeus was typing.
        public static let terminalChanged = "The Terminal input changed while Zeus was typing, so it didn't press Return. Check the draft in Terminal."
        /// The pane's tmux server isn't known.
        public static let terminalNotFound = "Restart your assistant so Zeus can find its Terminal pane."
        /// The chosen pane is on a different tmux server from the assistant.
        public static let terminalOtherServer = "Your assistant's Terminal pane is on a different tmux server. Choose its pane in Settings → Assistant."

        /// The OpenCode server URL isn't http or https.
        public static let openCodeInvalidURL = "Enter an OpenCode server URL that starts with http:// or https:// in Settings → Assistant."
        /// The OpenCode username (from the environment) contains a colon.
        public static let openCodeInvalidUsername = "Your OpenCode username (OPENCODE_SERVER_USERNAME) can't contain a colon. Change it, then reopen Zeus."
        /// OpenCode rejected the password (HTTP 401 or 403).
        public static let openCodePasswordRejected = "OpenCode didn't accept the password. Check it in Settings → Assistant."
        /// OpenCode doesn't know the chosen conversation (HTTP 404).
        public static let openCodeConversationNotFound = "OpenCode can't find the chosen conversation. Choose it again in Settings → Assistant."
        /// OpenCode accepted the request but didn't confirm the message.
        public static let openCodeUnconfirmed = "OpenCode didn't confirm it got this message. Zeus will check and try again."

        /// Any other HTTP status from OpenCode. 401/403 and 404 get their own lines; the code stays for support.
        public static func openCodeStatus(_ status: Int) -> String {
            switch status {
            case 401, 403: openCodePasswordRejected
            case 404: openCodeConversationNotFound
            default: "OpenCode had a problem (error \(status)). Zeus will try again."
            }
        }

        /// The conversation's server isn't recorded yet (a choice saved before Round 4). Shown under a message.
        public static let openCodeChooseAgain = "Choose this OpenCode conversation again in Settings → Assistant to confirm its server."
        /// The chosen conversation belongs to a server other than the current URL; nothing has been sent yet.
        public static let openCodeSelectionOnOtherServer = "Your chosen OpenCode conversation is on another server. Choose one on this server in Settings → Assistant, and Zeus sends this there."
        /// Zeus already started sending this message to a server that is no longer the current URL (A3-9 pin).
        /// - Parameter server: the original server, e.g. "127.0.0.1:4096".
        public static func openCodePinnedToOtherServer(_ server: String) -> String {
            "Zeus started sending this to your OpenCode server at \(server). Change the server URL back to finish sending it, or discard it."
        }
        /// A pinned message whose original server isn't recorded: Zeus won't guess where it goes.
        public static let openCodeUnknownServer = "Zeus can't tell which OpenCode server this was going to, so it won't send it anywhere else. Discard it, then send it again."
        /// The chosen conversation belongs to a different folder from the connected OpenCode session.
        public static let openCodeOtherFolder = "The chosen OpenCode conversation is in a different folder. Choose the right one in Settings → Assistant."

        /// The assistant's connection to Zeus closed.
        public static let disconnected = "Your assistant disconnected. Zeus sends this when it's back."
        /// The assistant's connection didn't answer in time.
        public static let linkTimedOut = "Your assistant didn't respond in time. Zeus will try again."
        /// Any other connection failure.
        public static let linkFailed = "Zeus couldn't reach your assistant. It will try again."
    }

    /// OpenCode wording inside Settings → Assistant, next to the Conversation picker (A4D-11). It never sends the user to
    /// the pane they're already in, and calls a native session a "conversation", like the picker.
    public enum OpenCode {
        /// The picker's prompt when nothing is chosen. Use it as the picker's placeholder, never as a menu item.
        public static let choosePlaceholder = "Choose a conversation"
        /// A saved choice from before servers were recorded.
        public static let chooseAgainNotice = "Choose this conversation again to confirm which server it's on."
        /// The saved choice belongs to another server.
        /// - Parameter server: the saved choice's server, e.g. "127.0.0.1:4096".
        public static func otherServerNotice(_ server: String) -> String {
            "Your chosen conversation is on another server (\(server)). Choose one on this server to send your messages there."
        }
        /// No OpenCode session is connected yet.
        public static let notConnected = "Start OpenCode with Zeus, then choose it under Assistant session."
    }

    /// The managed assistant's status detail when Zeus can't start or keep it (MANAGED.md §3). The panel's title
    /// stays its usual one unless noted.
    public enum Managed {
        /// Zeus's saved record of the session doesn't fit together. Nothing was changed.
        public static let invalidState = "Zeus lost track of your assistant's setup, so it changed nothing. Start a new conversation to continue."
        /// The bundled bridge is missing from the app.
        public static let missingBridge = "Part of Zeus is missing. Reinstall Zeus."
        /// The tmux session Zeus made was changed or taken over outside Zeus.
        public static let ownershipChanged = "Zeus's Terminal session was changed outside Zeus, so Zeus left it alone. Start a new conversation."
        /// Zeus's session name is taken (Zeus normally picks another name by itself).
        public static let nameTaken = "Another Terminal session is already using Zeus's name. Close it, then start again."
        /// More than one saved agent conversation matches Zeus's marker.
        public static let ambiguousConversation = "Zeus found more than one conversation that could be your assistant's, so it won't guess. Start a new conversation."
        /// The agent's conversation store couldn't be read.
        public static let conversationStoreUnreadable = "Zeus couldn't read your assistant's saved conversations. Open Terminal to check on it, or start a new conversation."
        /// A tmux command failed while starting or checking the session. Its error text belongs in a log.
        public static let terminalFailed = "Zeus couldn't control its Terminal session. Open Terminal to check on your assistant, then try again."
        /// The new pane never became ready.
        public static let terminalNotReady = "Terminal didn't get ready in time. Try again."
        /// Terminal.app isn't installed.
        public static let terminalAppMissing = "Terminal isn't on this Mac. Copy the attach command and run it in your own terminal app."

        /// The panel title when the agent stopped before Zeus learned its conversation (A4D-6).
        public static let cantResumeTitle = "Can't resume this conversation"
        /// The detail for `cantResumeTitle`. Its fix is Start a New Conversation, not Try Again.
        /// - Parameter agent: "Codex" or "OpenCode".
        public static func cantResume(agent: String) -> String {
            "\(agent) stopped before it saved this conversation, so Zeus can't pick it up again. Start a new conversation."
        }
    }
}
