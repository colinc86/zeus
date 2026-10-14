import SwiftUI
import ZeusProtocol

/// A mock conversation panel in both appearances, plus the empty state and the warning popover.
/// Used by the `#Preview` below and by `zeus-sprites conversation` to render `docs/design/conversation-d5.png`.
public struct ZeusConversationGallery: View {
    public init() {}

    public var body: some View {
        HStack(alignment: .top, spacing: 0) {
            column(.dark) { MockPanel(showChip: true) }
            column(.light) { MockPanel(showChip: false) }
            column(.dark) {
                VStack(alignment: .leading, spacing: ZeusTheme.Spacing.xl) {
                    EmptyPanel()
                    ZeusWarningPopover(
                        message: "2 replies couldn't reach Claude (~/Zeus). It disconnected 6 min ago.",
                        footnote: "They'll be sent automatically when it reconnects.",
                        onRetry: {}, onDiscard: {})
                    ZeusWarningPopover(
                        message: "Claude Code is stopped. Start it to send 1 message.",
                        primary: .init(ZeusWarningPopover.Labels.startAssistant) {}, onDiscard: {})
                    ZeusPeekBubble(title: "Ship the build?", body: "Tests pass on **main**. Ship it, Zeus?",
                                   options: [CardOption(id: "ship", label: "Ship it", style: .primary),
                                             CardOption(id: "wait", label: "Not yet", style: .secondary)],
                                   moreCount: 2, tail: ZeusDialogTail(edge: .bottom, offset: 200),
                                   onOpen: {}, onClose: {})
                }
            }
        }
        .fixedSize()
    }

    private func column<Content: View>(_ scheme: ColorScheme, @ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(ZeusTheme.Spacing.xl)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(scheme == .dark ? Color(hex: 0x3B4256) : Color(hex: 0xD9DEE8))
            .environment(\.colorScheme, scheme)
    }
}

private let talkOptions = [
    CardOption(id: "yes", label: "Yes", style: .secondary),
    CardOption(id: "no", label: "No", style: .primary),
    CardOption(id: "later", label: "Remind me later", style: .secondary),
]

/// A thread mid-conversation: every bubble type, two sessions, live and answered questions.
private struct MockPanel: View {
    let showChip: Bool
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: ZeusTheme.Conversation.spacing) {
                ZeusThreadDivider("Today 8:02")
                VStack(alignment: .leading, spacing: ZeusTheme.Conversation.groupedSpacing) {
                    ZeusSessionLabel("Claude · Zeus", colorIndex: 0)
                    ZeusBubble(.agent) {
                        ZeusBubbleHeader(title: "Talk tomorrow", trailing: "8:02")
                        ZeusMarkdownText("Your talk on **Q3 planning** is tomorrow at 10:00. Have you started on it?")
                        ZeusOptionButtons(talkOptions, state: .answered(optionID: "no")) { _ in }
                    }
                }
                ZeusBubble(.user) { Text("No — can you take a first pass?") }
                ZeusBubble(.agent, muted: true) {
                    Text("Reminder set for 9:00.").fixedSize(horizontal: false, vertical: true)
                }
                ZeusBubble(.agent) {
                    ZeusBubbleHeader(title: "Drafting your talk", trailing: "8:05")
                    ZeusProgressRow(value: 0.62)
                }
                ZeusBubble(.agent) {
                    ZeusBubbleHeader(title: "Q3 talk: first draft", trailing: "8:31")
                    Text("12 slides from your planning notes. Slides 7–9 need your numbers.")
                    ZeusAttachmentRow(Attachment(id: "a", kind: .file, label: "Open Keynote draft", target: "~/Documents/Talks/Q3 Planning.key"),
                                      onOpen: {}, onReveal: {})
                }
                VStack(alignment: .leading, spacing: ZeusTheme.Conversation.groupedSpacing) {
                    ZeusSessionLabel("Codex · zeus-app", colorIndex: 2)
                    ZeusBubble(.agent, highPriority: true) {
                        ZeusBubbleHeader(title: "Ship the build?", trailing: "8:40")
                        ZeusMarkdownText("Tests pass on **main**. Tag `v0.3` and upload it?")
                        ZeusOptionButtons([CardOption(id: "ship", label: "Ship it", style: .primary),
                                           CardOption(id: "wait", label: "Not yet", style: .secondary)],
                                          state: .open(shortcuts: true)) { _ in }
                    }
                }
            }
            .padding(.bottom, ZeusTheme.Spacing.s)
            .overlay(alignment: .bottomTrailing) {
                ZeusJumpToLatest(newCount: 2) {}.offset(y: -ZeusTheme.Spacing.xs)
            }
            VStack(alignment: .leading, spacing: ZeusTheme.Spacing.s) {
                ZeusActivityRow("Uploading v0.3", progress: 0.4)
                ZeusComposer(text: $draft, placeholder: "Message Claude…",
                             replyingTo: showChip ? "Ship the build?" : nil,
                             focus: $focused, onClearReply: {}, onSend: {})
            }
            .padding(.top, ZeusTheme.Spacing.s)
            .overlay(alignment: .top) { Rectangle().fill(Color.secondary.opacity(0.25)).frame(height: ZeusTheme.pixel) }
        }
        .frame(width: ZeusTheme.Conversation.panelWidth - ZeusTheme.borderWidth * 2 - ZeusTheme.Spacing.m * 2)
        .zeusDialog(tail: ZeusDialogTail(edge: .bottom, offset: 300))
    }
}

private struct EmptyPanel: View {
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: ZeusTheme.Spacing.s) {
            ZeusEmptyThread(assistantName: "Claude").frame(height: 120)
            ZeusComposer(text: $draft, placeholder: "Message Claude…", focus: $focused, onClearReply: {}, onSend: {})
        }
        .frame(width: ZeusTheme.Conversation.panelWidth - ZeusTheme.borderWidth * 2 - ZeusTheme.Spacing.m * 2)
        .zeusDialog(tail: ZeusDialogTail(edge: .bottom, offset: 300))
    }
}

#Preview("Conversation") {
    let _ = ZeusFonts.registerBundled()
    ZeusConversationGallery()
}
