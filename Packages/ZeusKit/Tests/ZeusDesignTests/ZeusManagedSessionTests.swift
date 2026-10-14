import Foundation
import Testing
import ZeusProtocol
@testable import ZeusDesign

/// M3: the managed session's copy and components (docs/design/MANAGED.md).
struct ZeusManagedSessionTests {
    static let now = Date(timeIntervalSinceReferenceDate: 1_000)
    static let states: [ZeusManagedState] = [
        .off, .starting, .running(.idle), .running(.working), .running(.unknown), .blocked(reason: "Do you trust this folder?"),
        .stopped, .restarting(at: now.addingTimeInterval(9.2)), .failed(reason: "Claude Code quit 5 times in 10 minutes."),
    ]

    static func present(_ state: ZeusManagedState) -> ZeusManagedPresentation {
        .make(state, agent: "Claude Code", folder: "~/Assistant", session: "zeus", now: now)
    }

    @Test func everyStateHasCopyAndAPrimaryAction() {
        for state in Self.states {
            let p = Self.present(state)
            #expect(!p.title.isEmpty && !p.detail.isEmpty, "\(state)")
            #expect(!p.actions.isEmpty, "\(state)")
            #expect(Set(p.actions).count == p.actions.count, "\(state) repeats an action")
            #expect(p.accessibilityLabel.hasPrefix("Assistant: \(p.title)."))
            #expect(ZeusFonts.pixelFontMissingGlyphs(in: p.title + p.detail + (p.menuStatus ?? "")).isEmpty, "\(state)")
        }
    }

    /// CONTRACT §11.7, L13: the menu's first line describes the managed assistant in every state, running included.
    @Test func menuStatusForEveryState() {
        for state in Self.states { #expect(Self.present(state).menuStatus != nil, "\(state)") }
        #expect(Self.present(.running(.idle)).menuStatus == "Claude Code is ready")
        #expect(Self.present(.running(.working)).menuStatus == "Claude Code is working…")
        #expect(Self.present(.running(.unknown)).menuStatus == "Claude Code is running")
        #expect(Self.present(.blocked(reason: "x")).menuStatus == "Claude Code is waiting for you in Terminal")
        #expect(Self.present(.stopped).menuStatus == "Claude Code is stopped")
        #expect(Self.present(.off).menuStatus == "Your assistant is off")
    }

    @Test func tonesAndActionsFollowTheState() {
        #expect(Self.present(.running(.idle)).tone == .ok)
        #expect(Self.present(.running(.unknown)).title == "Running")           // unknown is not idle, but not a problem
        #expect(Self.present(.running(.working)).title == "Working")
        #expect(Self.present(.blocked(reason: "x")).tone == .attention)
        #expect(Self.present(.blocked(reason: "x")).actions.first == .openInTerminal)
        #expect(Self.present(.blocked(reason: "  ")).detail == "Claude Code is showing a prompt only you can answer.")
        #expect(Self.present(.failed(reason: "")).actions.first == .tryAgain)
        #expect(Self.present(.stopped).actions == [.start])                    // a clean exit isn't restarted
        #expect(Self.present(.restarting(at: Self.now.addingTimeInterval(9.2))).title == "Restarting in 10 s")
        #expect(Self.present(.restarting(at: Self.now.addingTimeInterval(-1))).title == "Restarting…")
        #expect(Self.present(.starting).detail == "Opening Claude Code in tmux session “zeus”.")
        #expect(ZeusManagedPresentation.Action.allCases.allSatisfy { !$0.title.isEmpty && !$0.menuTitle.isEmpty })
    }

    @Test func defaultLaunchPromptCoversTheBrief() {
        let prompt = ZeusManagedCopy.defaultLaunchPrompt
        for tool in ["zeus_say", "zeus_ask", "zeus_present", "zeus_set_status", "zeus_ack"] {
            #expect(prompt.contains(tool), "\(tool)")
        }
        #expect(prompt.hasPrefix("You are my personal assistant."))
        #expect(prompt.contains("desktop"))
        #expect(prompt.contains("Point first"))
        #expect(prompt.contains("check in briefly"))
        #expect(prompt.contains("\"auto\""))
        #expect(!prompt.contains("TODO"))
        // Passed as one argv item / TOML string on every launch: keep it short.
        #expect(prompt.count < 2_400, "\(prompt.count) characters")
        #expect(ZeusManagedCopy.firstMessage.contains("zeus_say"))
        #expect(ZeusManagedCopy.firstMessage.count <= 120)
    }

    @Test func blockedCardLeadsWithWhatToDoAndQuotesTheDialog() {
        let card = ZeusManagedCopy.blockedCard(agent: "Codex", dialog: "Allow command?\n\n  $ rm -rf build\n1\n2\n3\n4\n5")
        #expect(card.title == "Codex is waiting for you in Terminal")
        #expect(card.action == "Open in Terminal")
        #expect(card.body.hasPrefix("Answer it in Terminal."))
        #expect(card.body.contains("```\nAllow command?\n$ rm -rf build\n1\n2\n3\n```"))
        #expect(!card.body.contains("\n4"))
        let bare = ZeusManagedCopy.blockedCard(agent: "Codex", dialog: " \n ")
        #expect(!bare.body.contains("```"))
    }

    @Test func choiceRowsReadTagWarningAndDetail() {
        let risky = ZeusChoice(id: "yolo", title: "Bypass permissions", detail: "Never asks.", tag: "Unrestricted", isWarning: true)
        #expect(risky.accessibilityLabel == "Bypass permissions, Unrestricted, warning. Never asks.")
        #expect(ZeusChoice(id: 1, title: "Codex").accessibilityLabel == "Codex")
    }
}

/// R3c (D2-8): one naming rule for agents across the app.
@Test func agentNamesFollowOneRule() {
    #expect(ZeusAgentName.product(.claude) == "Claude Code")
    #expect(ZeusAgentName.short(.claude) == "Claude")
    #expect(ZeusAgentName.short(.opencode) == ZeusAgentName.product(.opencode))
    #expect(ZeusAgentName.composerPlaceholder(nil) == "Message your assistant…")
    #expect(ZeusAgentName.composerPlaceholder("Codex") == "Message Codex…")
    for agent in AgentKind.allCases {
        #expect(ZeusFonts.pixelFontMissingGlyphs(in: ZeusAgentName.product(agent) + ZeusAgentName.short(agent)).isEmpty)
    }

}

/// A4D-6: the can't-resume fix is a real panel action, worded like the Settings button and the popover.
@Test func newConversationIsAnAction() {
    let action = ZeusManagedPresentation.Action.newConversation
    #expect(action.title == "Start New Conversation" && action.menuTitle == action.title)
    #expect(ZeusWarningPopover.Labels.startNewConversation == action.title)
}

/// L10: Settings shows an attach command a person can read and type.
@Test func attachCommandIsShortAndExact() {
    #expect(ZeusManagedCopy.attachCommand(session: "zeus") == "tmux attach -t zeus")
    #expect(ZeusManagedCopy.attachCommand(session: "zeus-2") == "tmux attach -t zeus-2")
    #expect(ZeusManagedCopy.attachCommand(session: "zeus", socket: "/tmp/zeus test/tmux.sock")
            == "tmux -S '/tmp/zeus test/tmux.sock' attach -t zeus")
    #expect(ZeusManagedCopy.attachCommand(session: "zeus", socket: "/private/tmp/tmux-501/zeus") == "tmux -S /private/tmp/tmux-501/zeus attach -t zeus")
    #expect(ZeusManagedCopy.attachCommand(session: "it's") == "tmux attach -t 'it'\\''s'")
    for command in [ZeusManagedCopy.attachCommand(session: "zeus"), ZeusManagedCopy.attachCommand(session: "zeus", socket: "/tmp/a.sock")] {
        #expect(!command.contains("env") && !command.contains("TMUX") && !command.contains("%"))
    }
    #expect(ZeusManagedCopy.attachCaption == "Watch or type to it in Terminal:")
}

/// L13: the menu's first line names what the managed assistant is doing in every running activity.
@Test func runningMenuStatusCoversEveryActivity() {
    #expect(ZeusManagedCopy.runningMenuStatus(agent: "Claude Code", activity: .idle) == "Claude Code is ready")
    #expect(ZeusManagedCopy.runningMenuStatus(agent: "Codex", activity: .working) == "Codex is working…")
    #expect(ZeusManagedCopy.runningMenuStatus(agent: "OpenCode", activity: .unknown) == "OpenCode is running")
    for activity in [ZeusManagedState.Activity.idle, .working, .unknown] {
        let line = ZeusManagedCopy.runningMenuStatus(agent: "Claude Code", activity: activity)
        #expect(ZeusFonts.pixelFontMissingGlyphs(in: line).isEmpty)
        #expect(!line.contains("new message"))
    }
}
