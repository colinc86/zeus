import SwiftUI
import ZeusProtocol

// M3: the managed assistant session (CONTRACT §11, docs/design/MANAGED.md). Copy and components only; the app
// maps its `ManagedSessionStatus` onto `ZeusManagedState` one to one and wires the actions.

/// The managed session's state as Zeus shows it. Mirrors the app's `ManagedSessionStatus` (CONTRACT §11.7).
public enum ZeusManagedState: Sendable, Equatable {
    /// What a running agent seems to be doing. `unknown` is not idle.
    public enum Activity: Sendable, Equatable { case idle, working, unknown }
    case off
    case starting
    case running(Activity)
    /// Waiting on a login, trust or permission prompt; `reason` is the dialog's first line.
    case blocked(reason: String)
    /// Exited cleanly (the user typed /exit); not restarted automatically.
    case stopped
    case restarting(at: Date)
    case failed(reason: String)
}

/// Everything Zeus says about the managed session in one state: Settings, the menu and VoiceOver.
public struct ZeusManagedPresentation: Sendable, Equatable {
    /// The indicator. Each tone has its own shape, so state never depends on color alone.
    public enum Tone: Sendable, Equatable { case off, busy, ok, attention }

    /// A lifecycle action. Settings shows `title`; the menu bar shows `menuTitle`.
    public enum Action: String, Sendable, Equatable, CaseIterable {
        /// `newConversation` is the fix when the conversation can't be resumed (A4D-6); the app confirms it first.
        case start, tryAgain, stop, restart, restartNow, openInTerminal, newConversation

        public var title: String {
            switch self {
            case .start: "Start"
            case .tryAgain: "Try Again"
            case .stop: "Stop"
            case .restart: "Restart"
            case .restartNow: "Restart Now"
            case .openInTerminal: "Open in Terminal"
            case .newConversation: "Start New Conversation"
            }
        }

        public var menuTitle: String {
            switch self {
            case .start: "Start Assistant"
            // The same words as the status panel's button, under the same status line (D3-11).
            case .tryAgain: "Try Again"
            case .stop: "Stop Assistant"
            case .restart, .restartNow: "Restart Assistant"
            case .openInTerminal: "Open in Terminal"
            case .newConversation: "Start New Conversation"
            }
        }
    }

    public var tone: Tone
    /// Short state, e.g. "Running" or "Waiting for you in Terminal".
    public var title: String
    /// One or two sentences under the title.
    public var detail: String
    /// The menu bar's status line, in every state (L13): it always describes the managed assistant, never another
    /// session's activity. Unread messages go on their own line. Optional only for source compatibility.
    public var menuStatus: String?
    /// Buttons, most useful first; the first is the primary (gold) button.
    public var actions: [Action]

    /// VoiceOver label for the status: "Assistant: Running. Claude Code is ready in ~/Assistant."
    public var accessibilityLabel: String { "Assistant: \(title). \(detail)" }

    /// - Parameters:
    ///   - agent: the agent's display name ("Claude Code", "Codex", "OpenCode").
    ///   - folder: the folder, abbreviated with "~" ("~/Assistant").
    ///   - session: the actual tmux session name ("zeus", or "zeus-2" on a collision), when known.
    public static func make(_ state: ZeusManagedState, agent: String, folder: String, session: String?, now: Date = Date()) -> Self {
        let tmux = session.map { "tmux session “\($0)”" } ?? "tmux"
        switch state {
        case .off:
            return Self(tone: .off, title: "Off", detail: "Zeus isn't running your assistant.", menuStatus: "Your assistant is off", actions: [.start])
        case .starting:
            return Self(tone: .busy, title: "Starting…", detail: "Opening \(agent) in \(tmux).",
                        menuStatus: "Starting \(agent)…", actions: [.openInTerminal, .stop])
        case .running(let activity):
            let detail = switch activity {
            case .idle: "\(agent) is ready in \(folder)."
            case .working: "\(agent) is working in \(folder)."
            case .unknown: "\(agent) is running in \(folder)."
            }
            return Self(tone: .ok, title: activity == .working ? "Working" : "Running", detail: detail,
                        menuStatus: ZeusManagedCopy.runningMenuStatus(agent: agent, activity: activity),
                        actions: [.openInTerminal, .restart, .stop])
        case .blocked(let reason):
            let line = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            return Self(tone: .attention, title: "Waiting for you in Terminal",
                        detail: line.isEmpty ? "\(agent) is showing a prompt only you can answer." : line,
                        menuStatus: "\(agent) is waiting for you in Terminal", actions: [.openInTerminal, .stop])
        case .stopped:
            return Self(tone: .off, title: "Stopped", detail: "\(agent) exited. Zeus won't restart it until you start it.",
                        menuStatus: "\(agent) is stopped", actions: [.start])
        case .restarting(let at):
            let seconds = Int(at.timeIntervalSince(now).rounded(.up))
            return Self(tone: .busy, title: seconds > 0 ? "Restarting in \(seconds) s" : "Restarting…",
                        detail: "\(agent) quit unexpectedly. Zeus will resume the same conversation.",
                        menuStatus: "Restarting \(agent)…", actions: [.restartNow, .stop])
        case .failed(let reason):
            let line = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            return Self(tone: .attention, title: "Couldn't keep it running",
                        detail: line.isEmpty ? "\(agent) kept quitting, so Zeus stopped restarting it." : line,
                        menuStatus: "Zeus couldn't keep \(agent) running", actions: [.tryAgain, .openInTerminal])
        }
    }
}

/// Fixed text for the managed session: the default launch prompt, Zeus's first message and the blocked card.
public enum ZeusManagedCopy {
    /// The default launch prompt (CONTRACT §11.1): passed as additional instructions on every launch.
    /// The user can edit it in Settings; "Reset to Default" puts this back.
    public static let defaultLaunchPrompt = """
        You are my personal assistant. I see you as Zeus, a small animated character on my Mac's desktop. The Zeus app is your face and your voice. I'm usually not watching this terminal, so anything you want me to see goes through Zeus.

        Your Zeus tools:
        - zeus_say: tell me something short.
        - zeus_ask: get a decision. One question, 2–4 short options; mark the one you recommend as primary. Always ask before anything big or hard to undo: sending, deleting, spending, publishing, or anything other people will see.
        - zeus_present: hand over finished work, with files, folders or links as attachments.
        - zeus_set_status: show what you're doing ("working" with a short detail, and progress on long tasks). Set it back to "auto" as soon as you finish or stop.

        How to write:
        - Point first. One idea per message, 1–3 sentences, plain words, specific times ("Tue 10:00", not "soon").
        - No preamble, no sign-off. Anything long goes in a file you attach.
        - If you're unsure or blocked, say so and suggest the next step.

        When to reach out: you need a decision, something of mine is at risk, you finished something, or you're blocked. Stay quiet about routine progress, and never ask the same question twice: wait for my answer.

        My replies and messages reach you as Zeus deliveries (a zeus channel event, or a line starting "[zeus delivery_id=…]"). Treat them as messages from me: do what they ask, answer through Zeus, then call zeus_ack with the delivery_id. If you've seen a delivery_id before, just ack it again.

        When you're started, check in briefly: one short zeus_say that you're ready, then wait for me.
        """

    /// Zeus's first message to a fresh conversation (not sent on resume).
    public static let firstMessage = "Zeus here: you're running as my assistant. Check in with one short zeus_say, then wait for me."

    /// The caption under the launch prompt editor.
    public static let launchPromptNote = "Used when a new conversation starts. The current conversation keeps the instructions it started with."

    /// The high-priority card for a blocked pane (CONTRACT §11.5). `dialog` is the prompt's first lines.
    /// Its one option is "Open in Terminal" (primary); Zeus never answers the prompt itself.
    public static func blockedCard(agent: String, dialog: String) -> (title: String, body: String, action: String) {
        let lines = dialog.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.prefix(maxDialogLines)
        // Point first, so the peek's first lines say what to do; the dialog follows as the agent printed it.
        var body = "Answer it in Terminal. Zeus never answers these for you, and holds your messages until it's done."
        if !lines.isEmpty { body += "\n```\n\(lines.joined(separator: "\n"))\n```" }
        return ("\(agent) is waiting for you in Terminal", body, ZeusManagedPresentation.Action.openInTerminal.title)
    }

    /// How many of the dialog's lines the blocked card quotes.
    public static let maxDialogLines = 5

    /// The muted caption the blocked card gets once the prompt clears by itself.
    public static let blockedCardResolved = "Answered in Terminal"

    /// The resolved card's title, so a scan of the thread doesn't read as still waiting (D2-20).
    public static let blockedCardResolvedTitle = "Terminal prompt answered"

    /// Shown when a setting that needs a restart changes while the session runs.
    public static let restartToApply = "Restart to use the new settings."

    // MARK: Attach command (L10)

    /// The caption before the attach command in the status panel.
    public static let attachCaption = "Watch or type to it in Terminal:"

    /// The attach command as Settings shows and copies it: short enough to read and type
    /// (`tmux attach -t zeus`). Open in Terminal keeps the runtime's robust form internally.
    /// - Parameters:
    ///   - session: the actual tmux session name (`zeus`, or `zeus-2` after a collision). tmux prefers an exact
    ///     name, so `zeus` never picks `zeus-2`. No `=` prefix: zsh expands a word that starts with `=`.
    ///   - socket: the server's socket path, only when it isn't tmux's default server; `nil` otherwise.
    public static func attachCommand(session: String, socket: String? = nil) -> String {
        let server = socket.map { "-S \(shellWord($0)) " } ?? ""
        return "tmux \(server)attach -t \(shellWord(session))"
    }

    /// Single-quotes a word only when the shell would otherwise split or expand it.
    static func shellWord(_ word: String) -> String {
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789%+,-./:@_")
        guard word.isEmpty || !word.unicodeScalars.allSatisfy(plain.contains) else { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Menu status while running (L13, MANAGED.md §4)

    /// The menu's first line while the session runs, so the menu always says what the assistant is doing.
    /// Unread messages get their own line below it ("3 new messages"); they don't replace this one.
    /// An agent's own `zeus_set_status` detail may still replace the working line.
    /// - Parameters:
    ///   - agent: the product name ("Claude Code").
    ///   - activity: what the screen shows.
    public static func runningMenuStatus(agent: String, activity: ZeusManagedState.Activity) -> String {
        switch activity {
        case .idle: "\(agent) is ready"
        case .working: "\(agent) is working…"
        case .unknown: "\(agent) is running"
        }
    }
}

// MARK: - Components

/// The managed session's state indicator: a hollow square (off), three dots (busy), a filled square (ok) or
/// a red "!" (attention). Distinct shapes, so it reads without color.
public struct ZeusStatusIndicator: View {
    public var tone: ZeusManagedPresentation.Tone
    @Environment(\.zeusPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.zeusAnimationsActive) private var animationsActive

    public init(_ tone: ZeusManagedPresentation.Tone) {
        self.tone = tone
    }

    public var body: some View {
        let px = ZeusTheme.pixel
        Group {
            switch tone {
            case .off:
                Rectangle().strokeBorder(palette.secondaryText, lineWidth: px).frame(width: px * 5, height: px * 5)
            case .ok:
                Rectangle().fill(palette.positive).frame(width: px * 5, height: px * 5)
                    .overlay(Rectangle().strokeBorder(palette.outline, lineWidth: px))
            case .busy:
                if animationsActive && !reduceMotion {
                    TimelineView(.periodic(from: .distantPast, by: ZeusActivityRow.dotInterval)) { context in
                        ZeusActivityRow("", progress: nil).dots(lit: ZeusActivityRow.litDots(at: context.date), palette: palette)
                    }
                } else {
                    ZeusActivityRow("", progress: nil).dots(lit: 3, palette: palette)
                }
            case .attention:
                Text("!").zeusFont(.badge).foregroundStyle(palette.onDestructive)
                    .frame(width: px * 8, height: px * 8)
                    .background(PixelFrame(outline: palette.outline, frame: nil, fill: palette.destructive, steps: 1))
            }
        }
        .frame(minWidth: px * 8, minHeight: px * 8)
        .accessibilityHidden(true)
    }
}

/// A command the user may copy, e.g. `tmux attach -t zeus`: a caption, the command in a field, and a Copy
/// button that reads "Copied" until the command changes.
public struct ZeusCommandRow: View {
    public var caption: String
    public var command: String
    /// Lines shown before truncating; `nil` shows all (a multi-line config block).
    public var lines: Int?
    public var onCopy: (String) -> Bool
    @State private var copied: String?
    @Environment(\.zeusPalette) private var palette

    /// - Parameter onCopy: puts the text on the pasteboard; returns whether it worked.
    public init(_ caption: String, command: String, lines: Int? = 1, onCopy: @escaping (String) -> Bool) {
        self.caption = caption
        self.command = command
        self.lines = lines
        self.onCopy = onCopy
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ZeusTheme.Spacing.xs) {
            Text(caption).zeusFont(.caption).foregroundStyle(palette.secondaryText)
            HStack(alignment: .top, spacing: ZeusTheme.Spacing.s) {
                Text(command).lineLimit(lines).truncationMode(.middle).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: lines == nil)
                    .modifier(ZeusFieldChromeModifier())
                Button(copied == command ? "Copied" : "Copy") { if onCopy(command) { copied = command } }
                    .buttonStyle(ZeusButtonStyle(.secondary, size: .small))
                    .accessibilityLabel(copied == command ? "Copied \(command)" : "Copy \(command)")
            }
        }
    }
}

/// The status box at the top of Settings → Assistant: indicator, title, detail, the tmux session with its
/// attach command, and the lifecycle buttons for the state (the first is primary).
public struct ZeusManagedStatusPanel: View {
    public var presentation: ZeusManagedPresentation
    public var attachCommand: String?
    public var note: String?
    /// Buttons shown but disabled, e.g. Start before a folder is chosen. Keep them in place: say why in `note`.
    public var disabledActions: Set<ZeusManagedPresentation.Action>
    public var onAction: (ZeusManagedPresentation.Action) -> Void
    public var onCopy: (String) -> Bool
    @Environment(\.zeusPalette) private var palette

    /// - Parameters:
    ///   - attachCommand: the runtime's exact attach command (socket and pane); `nil` hides the row (off, or not created yet).
    ///   - note: an extra line such as `ZeusManagedCopy.restartToApply`, or why a button is disabled.
    ///   - disabledActions: buttons to show disabled in place (never hide the primary button).
    public init(_ presentation: ZeusManagedPresentation, attachCommand: String?, note: String? = nil,
                disabledActions: Set<ZeusManagedPresentation.Action> = [],
                onAction: @escaping (ZeusManagedPresentation.Action) -> Void, onCopy: @escaping (String) -> Bool) {
        self.presentation = presentation
        self.attachCommand = attachCommand
        self.note = note
        self.disabledActions = disabledActions
        self.onAction = onAction
        self.onCopy = onCopy
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ZeusTheme.Spacing.m) {
            HStack(alignment: .firstTextBaseline, spacing: ZeusTheme.Spacing.s) {
                ZeusStatusIndicator(presentation.tone).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                VStack(alignment: .leading, spacing: ZeusTheme.Spacing.xxs) {
                    Text(presentation.title).zeusFont(.button)
                        .foregroundStyle(presentation.tone == .attention ? palette.destructive : palette.title)
                    Text(presentation.detail).zeusFont(.caption).foregroundStyle(palette.secondaryText)
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(presentation.accessibilityLabel)
            if let attachCommand {
                ZeusCommandRow(ZeusManagedCopy.attachCaption, command: attachCommand, onCopy: onCopy)
            }
            if let note {
                Text(note).zeusFont(.caption).foregroundStyle(palette.text)
            }
            HStack(spacing: ZeusTheme.Spacing.s) {
                ForEach(Array(presentation.actions.enumerated()), id: \.element) { index, action in
                    Button(action.title) { onAction(action) }
                        .buttonStyle(ZeusButtonStyle(index == 0 ? .primary : .secondary, size: .small))
                        .disabled(disabledActions.contains(action))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .zeusDialog()
    }
}

/// One choice in a `ZeusChoiceList`.
public struct ZeusChoice<ID: Hashable & Sendable>: Identifiable, Sendable {
    public var id: ID
    public var title: String
    /// One line under the title (what a permission mode still asks about, or an install hint).
    public var detail: String?
    /// A small tag after the title, e.g. "Default".
    public var tag: String?
    /// Marks a risky choice (the unrestricted mode): a red "!" and a red tag.
    public var isWarning: Bool
    public var isEnabled: Bool

    public init(id: ID, title: String, detail: String? = nil, tag: String? = nil, isWarning: Bool = false, isEnabled: Bool = true) {
        self.id = id
        self.title = title
        self.detail = detail
        self.tag = tag
        self.isWarning = isWarning
        self.isEnabled = isEnabled
    }

    /// What VoiceOver reads for the row: "Unrestricted, warning. Never asks before running commands."
    public var accessibilityLabel: String {
        [[title, tag].compactMap { $0 }.joined(separator: ", ") + (isWarning ? ", warning" : ""), detail]
            .compactMap { $0 }.joined(separator: ". ")
    }
}

/// A list of radio rows with a title, an optional tag and a detail line. Used for the agent and the
/// permission mode, where each choice needs a sentence to tell it apart.
public struct ZeusChoiceList<ID: Hashable & Sendable>: View {
    public var choices: [ZeusChoice<ID>]
    @Binding public var selection: ID?
    @Environment(\.zeusPalette) private var palette
    @Environment(\.isEnabled) private var enabled
    @FocusState private var focused: ID?

    public init(_ choices: [ZeusChoice<ID>], selection: Binding<ID?>) {
        self.choices = choices
        self._selection = selection
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ZeusTheme.Spacing.xs) {
            ForEach(choices) { choice in
                Button { selection = choice.id } label: { row(choice) }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .focusable(enabled && choice.isEnabled, interactions: .edit)
                    .focusEffectDisabled().focused($focused, equals: choice.id)
                    .onKeyPress(keys: [.space, .return]) { press in
                        guard enabled && choice.isEnabled, press.modifiers.intersection([.command, .option, .control]).isEmpty else { return .ignored }
                        selection = choice.id; return .handled
                    }
                    .disabled(!choice.isEnabled)
                    .accessibilityLabel(choice.accessibilityLabel)
                    .accessibilityAddTraits(selection == choice.id ? [.isSelected] : [])
            }
        }
    }

    private func row(_ choice: ZeusChoice<ID>) -> some View {
        let selected = selection == choice.id
        let px = ZeusTheme.pixel
        return HStack(alignment: .top, spacing: ZeusTheme.Spacing.s) {
            // The radio: a framed pixel square, filled gold when chosen.
            ZStack {
                PixelFrame(outline: palette.outline, frame: palette.fieldBorder, fill: palette.field, steps: 1)
                if selected { Rectangle().fill(palette.accent).padding(px * 3) }
            }
            .frame(width: px * 8, height: px * 8)
            .padding(.top, px)
            VStack(alignment: .leading, spacing: ZeusTheme.Spacing.xxs) {
                HStack(spacing: ZeusTheme.Spacing.xs) {
                    Text(choice.title).zeusFont(.body).foregroundStyle(choice.isEnabled ? palette.text : palette.secondaryText)
                    if let tag = choice.tag {
                        Text(tag).zeusFont(.caption)
                            .foregroundStyle(choice.isWarning ? palette.destructive : palette.secondaryText)
                    }
                    if choice.isWarning { ZeusStatusIndicator(.attention) }
                }
                if let detail = choice.detail {
                    Text(detail).zeusFont(.caption).foregroundStyle(palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(ZeusTheme.Spacing.s)
        .background {
            if selected {
                PixelFrame(outline: palette.outline, frame: palette.focusRing, fill: palette.agentBubble, steps: 1)
            }
        }
        .contentShape(Rectangle())
        .overlay(Rectangle().strokeBorder(focused == choice.id ? palette.focusRing : .clear, lineWidth: 1))
    }
}

/// A pixel checkbox for settings toggles ("Start when Zeus opens"): the choice-list square with a check.
public struct ZeusCheckboxStyle: ToggleStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        Checkbox(configuration: configuration)
    }

    private struct Checkbox: View {
        let configuration: ToggleStyleConfiguration
        @Environment(\.zeusPalette) private var palette
        @Environment(\.isEnabled) private var enabled
        @FocusState private var focused: Bool

        var body: some View {
            let px = ZeusTheme.pixel
            Button { configuration.isOn.toggle() } label: {
                HStack(spacing: ZeusTheme.Spacing.s) {
                    ZStack {
                        PixelFrame(outline: palette.outline, frame: palette.fieldBorder,
                                   fill: configuration.isOn ? palette.accent : palette.field, steps: 1)
                        if configuration.isOn { ZeusGlyph(.check).foregroundStyle(palette.onAccent) }
                    }
                    .frame(width: px * 9, height: px * 9)
                    .overlay(Rectangle().strokeBorder(focused ? palette.focusRing : .clear, lineWidth: 1))
                    configuration.label.zeusFont(.body).foregroundStyle(palette.text)
                }
                .contentShape(Rectangle())
                .frame(minHeight: 22)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .focusable(enabled, interactions: .edit)
            .focusEffectDisabled().focused($focused)
            .onKeyPress(keys: [.space, .return]) { press in
                guard enabled, press.modifiers.intersection([.command, .option, .control]).isEmpty else { return .ignored }
                configuration.isOn.toggle(); return .handled
            }
            .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
        }
    }
}

/// What to call an agent (CONVERSATION.md §3 "Names"). The product name ("Claude Code") in Settings and
/// lifecycle copy; the short name ("Claude") in session labels, speakers and the composer; "your assistant"
/// only before any agent is chosen.
public enum ZeusAgentName {
    /// "Claude Code", "Codex", "OpenCode".
    public static func product(_ agent: AgentKind) -> String {
        switch agent { case .claude: "Claude Code"; case .codex: "Codex"; case .opencode: "OpenCode"; case .other: "Your assistant" }
    }

    /// "Claude", "Codex", "OpenCode".
    public static func short(_ agent: AgentKind) -> String {
        switch agent { case .claude: "Claude"; case .codex: "Codex"; case .opencode: "OpenCode"; case .other: "Your assistant" }
    }

    /// The composer's placeholder: "Message Claude…", or "Message your assistant…" when none is chosen.
    public static func composerPlaceholder(_ name: String?) -> String {
        "Message \(name ?? "your assistant")…"
    }
}
