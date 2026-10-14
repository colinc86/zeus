import SwiftUI
import ZeusProtocol

/// M3 mockups of the managed session (docs/design/MANAGED.md), built only from ZeusDesign components.
/// Rendered by the design harness (`scripts/design-harness/render.sh ManagedSessionMockups`) in every look.
public struct ZeusManagedSessionGallery: View {
    /// Which mockup to draw.
    public enum Scene: String, CaseIterable, Sendable {
        /// Settings → Assistant with Zeus running the assistant.
        case settings
        /// The status panel in every state.
        case states
        /// The blocked-prompt card in the thread and as a peek.
        case blockedCard
    }

    public var scene: Scene
    /// A fixed clock, so "Restarting in 10 s" renders the same every time.
    public var now: Date

    public init(_ scene: Scene, now: Date = Date(timeIntervalSinceReferenceDate: 0)) {
        self.scene = scene
        self.now = now
    }

    public var body: some View {
        switch scene {
        case .settings: MockAssistantSettings(now: now).frame(width: 524)
        case .states: MockStates(now: now).frame(width: 420)
        case .blockedCard: MockBlockedCard()
        }
    }
}

private let agent = "Claude Code"
private let folder = "~/Assistant"

/// Claude Code's permission modes as platform lists them (`permissionModes(for:)`, MANAGED.md §1.1), in order.
private let claudeModes: [ZeusChoice<String>] = [
    ZeusChoice(id: "manual", title: "Ask first", detail: "Asks before editing files or running commands.", tag: "Default"),
    ZeusChoice(id: "plan", title: "Plan only", detail: "Looks around and proposes a plan; asks before acting on it."),
    ZeusChoice(id: "dontAsk", title: "Never ask", detail: "Does only what you've already allowed; refuses the rest without asking."),
    ZeusChoice(id: "acceptEdits", title: "Accept edits", detail: "Edits files without asking; asks before other commands."),
    ZeusChoice(id: "auto", title: "Auto", detail: "A safety check approves routine actions; asks about the rest. Some models fall back to Ask first."),
    ZeusChoice(id: "bypassPermissions", title: "Bypass permissions",
               detail: "Never asks. It can run any command and change any file you can. Confirm once in Terminal the first time.",
               tag: "Unrestricted", isWarning: true),
]

private struct MockAssistantSettings: View {
    let now: Date
    @State private var mode = "Zeus runs it"
    @State private var agentID: String? = "claude"
    @State private var permission: String? = "manual"
    @State private var prompt = ZeusManagedCopy.defaultLaunchPrompt
    @State private var startAtLaunch = true
    @Environment(\.zeusPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: ZeusTheme.Spacing.l) {
            HStack(spacing: ZeusTheme.Spacing.s) {
                ForEach(["Zeus runs it", "Connect your own"], id: \.self) { option in
                    Button(option) { mode = option }
                        .buttonStyle(ZeusButtonStyle(mode == option ? .primary : .secondary, size: .small))
                        .accessibilityAddTraits(mode == option ? [.isSelected] : [])
                }
            }
            ZeusManagedStatusPanel(.make(.running(.idle), agent: agent, folder: folder, session: "zeus", now: now),
                                   attachCommand: "tmux attach -t zeus", note: ZeusManagedCopy.restartToApply,
                                   onAction: { _ in }, onCopy: { _ in true })
            section("Agent") {
                ZeusChoiceList([
                    ZeusChoice(id: "claude", title: "Claude Code", detail: "2.1.296"),
                    ZeusChoice(id: "codex", title: "Codex", detail: "0.162.1"),
                    ZeusChoice(id: "opencode", title: "OpenCode", detail: "Not installed. brew install sst/tap/opencode", isEnabled: false),
                ], selection: $agentID)
            }
            section("Folder") {
                HStack(spacing: ZeusTheme.Spacing.s) {
                    Text(folder).lineLimit(1).truncationMode(.middle).modifier(ZeusFieldChromeModifier())
                    Button("Choose…") {}.buttonStyle(ZeusButtonStyle(.secondary, size: .small))
                }
                caption("It works here, and reads this folder's CLAUDE.md or AGENTS.md.")
            }
            section("Permissions") {
                ZeusChoiceList(claudeModes, selection: $permission)
                caption("Claude Code's own modes. When it asks, Zeus shows a card that opens Terminal.")
            }
            section("Instructions") {
                TextEditor(text: $prompt)
                    .scrollContentBackground(.hidden)
                    .frame(height: 132)
                    .modifier(ZeusFieldChromeModifier())
                caption(ZeusManagedCopy.launchPromptNote)
                HStack(spacing: ZeusTheme.Spacing.s) {
                    Button("Start a New Conversation") {}.buttonStyle(ZeusButtonStyle(.secondary, size: .small))
                    Button("Reset to Default") {}.buttonStyle(ZeusButtonStyle(.secondary, size: .small)).disabled(true)
                }
            }
            Toggle("Start when Zeus opens", isOn: $startAtLaunch).toggleStyle(ZeusCheckboxStyle())
        }
        .padding(ZeusTheme.Spacing.xl)
        .background(palette.panel)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: ZeusTheme.Spacing.s) {
            Text(title).zeusFont(.title).foregroundStyle(palette.title).accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).zeusFont(.caption).foregroundStyle(palette.secondaryText).fixedSize(horizontal: false, vertical: true)
    }
}

private struct MockStates: View {
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: ZeusTheme.Spacing.l) {
            ZeusManagedStatusPanel(.make(.off, agent: agent, folder: folder, session: nil, now: now), attachCommand: nil,
                                   note: "Choose a folder to start.", disabledActions: [.start], onAction: { _ in }, onCopy: { _ in true })
            panel(.starting, attach: "tmux attach -t zeus")
            panel(.running(.working), attach: "tmux attach -t zeus")
            panel(.blocked(reason: "Do you want to proceed? ❯ 1. Yes  2. No"), attach: "tmux attach -t zeus")
            panel(.restarting(at: now.addingTimeInterval(10)), attach: "tmux attach -t zeus-2", session: "zeus-2")
            panel(.failed(reason: "Claude Code quit 5 times in 10 minutes."), attach: "tmux attach -t zeus")
            panel(.stopped, attach: "tmux attach -t zeus")
        }
        .padding(ZeusTheme.Spacing.xl)
    }

    private func panel(_ state: ZeusManagedState, attach: String?, session: String = "zeus") -> some View {
        ZeusManagedStatusPanel(.make(state, agent: agent, folder: folder, session: session, now: now),
                               attachCommand: attach, onAction: { _ in }, onCopy: { _ in true })
    }
}

private struct MockBlockedCard: View {
    private let card = ZeusManagedCopy.blockedCard(agent: agent, dialog: """
        Bash command
          rm -rf build/cache
        Do you want to proceed?
        ❯ 1. Yes
          2. No
        """)

    var body: some View {
        HStack(alignment: .top, spacing: ZeusTheme.Spacing.xl) {
            VStack(alignment: .leading, spacing: ZeusTheme.Conversation.groupedSpacing) {
                ZeusSessionLabel("Claude Code · Assistant", colorIndex: 0)
                ZeusBubble(.agent, highPriority: true) {
                    ZeusBubbleHeader(title: card.title, trailing: "9:41")
                    ZeusMarkdownText(card.body)
                    ZeusOptionButtons([CardOption(id: "open-terminal", label: card.action, style: .primary)],
                                      state: .open(shortcuts: true), action: { _ in })
                }
                .frame(width: ZeusTheme.Conversation.agentBubbleMaxWidth)
                ZeusBubble(.agent, muted: true) {
                    ZeusBubbleHeader(title: card.title, trailing: "9:41")
                    Text(ZeusManagedCopy.blockedCardResolved).zeusFont(.caption)
                }
                .frame(width: ZeusTheme.Conversation.agentBubbleMaxWidth)
            }
            ZeusPeekBubble(title: card.title, body: card.body,
                           options: [CardOption(id: "open-terminal", label: card.action, style: .primary)],
                           moreCount: 0, highPriority: true, tail: ZeusDialogTail(edge: .bottom, offset: 220), onOpen: {}, onClose: {})
        }
        .padding(ZeusTheme.Spacing.xl)
    }
}
