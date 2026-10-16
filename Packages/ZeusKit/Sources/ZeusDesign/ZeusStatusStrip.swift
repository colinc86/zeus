import SwiftUI

// MARK: - Model

/// What the conversation's status strip shows (TB1, CONVERSATION.md §15): a sentence that matches the avatar, the jump
/// link, an optional Skip link and the small buttons on the right. Plain data, so the app maps its state to it with a pure
/// function and the design harness renders it. Build sentences with the factories below so the copy stays in one place.
public struct ZeusStatusStripModel: Equatable, Sendable {
    /// The avatar glyph shown before the sentence.
    public enum Glyph: String, Equatable, Sendable {
        case question = "?"
        case alert = "!"
    }

    /// One of the strip's icon buttons, in display order.
    public enum Button: String, CaseIterable, Equatable, Sendable, Identifiable {
        case terminal, newConversation, clear, settings

        public var id: String { rawValue }

        /// The tooltip and accessibility label. An ellipsis means a confirmation or window follows.
        public var title: String {
            switch self {
            case .terminal: ZeusManagedPresentation.Action.openInTerminal.title
            case .newConversation: ZeusManagedPresentation.Action.newConversation.title + "…"
            case .clear: "Clear Conversation…"
            case .settings: "Assistant Settings…"
            }
        }

        /// The 12 × 12 pixel icon, top row first; "#" is filled.
        public var rows: [String] {
            switch self {
            case .terminal: [
                "############",
                "############",
                "#..........#",
                "#..........#",
                "#.#........#",
                "#..#.......#",
                "#...#......#",
                "#..#.......#",
                "#.#..####..#",
                "#..........#",
                "#..........#",
                "############",
            ]
            case .newConversation: [
                "############",
                "#..........#",
                "#....##....#",
                "#....##....#",
                "#..######..#",
                "#..######..#",
                "#....##....#",
                "#....##....#",
                "#..........#",
                "############",
                "..##........",
                "..#.........",
            ]
            case .clear: [
                "....####....",
                "############",
                "............",
                ".##########.",
                ".#..#..#..#.",
                ".#..#..#..#.",
                ".#..#..#..#.",
                ".#..#..#..#.",
                ".#..#..#..#.",
                ".#..#..#..#.",
                ".#........#.",
                "..########..",
            ]
            case .settings: [
                "....####....",
                ".##.####.##.",
                ".##########.",
                "..###..###..",
                "####....####",
                "###......###",
                "###......###",
                "####....####",
                "..###..###..",
                ".##########.",
                ".##.####.##.",
                "....####....",
            ]
            }
        }
    }

    /// A right-side button and whether it can be pressed now.
    public struct Item: Equatable, Sendable, Identifiable {
        public var button: Button
        public var isEnabled: Bool
        public var id: String { button.id }

        public init(_ button: Button, isEnabled: Bool = true) {
            self.button = button
            self.isEnabled = isEnabled
        }
    }

    /// "?" or "!", or nil for none.
    public var glyph: Glyph?
    /// "Waiting for your answer", "3 unread", "Claude is working on tests", "Idle".
    public var sentence: String
    /// The jump link after the sentence ("Go to question"); nil when the sentence does nothing (quiet hours, idle).
    public var actionTitle: String?
    /// "Skip" beside a waiting sentence; nil otherwise.
    public var skipTitle: String?
    /// Idle and quiet hours draw the sentence in secondary text.
    public var isQuiet: Bool
    /// The right-side buttons, in `Button.allCases` order. Leave out the ones that don't apply (no terminal, not managed).
    public var buttons: [Item]

    public init(glyph: Glyph? = nil, sentence: String, actionTitle: String? = nil, skipTitle: String? = nil,
                isQuiet: Bool = false, buttons: [Item] = []) {
        self.glyph = glyph
        self.sentence = sentence
        self.actionTitle = actionTitle
        self.skipTitle = skipTitle
        self.isQuiet = isQuiet
        self.buttons = buttons
    }

    /// The sentence as VoiceOver reads it: the glyph spoken, then the sentence.
    public var spokenSentence: String {
        switch glyph {
        case .question?: "Question. \(sentence)"
        case .alert?: "Alert. \(sentence)"
        case nil: sentence
        }
    }
}

// MARK: - Copy (one factory per avatar state)

extension ZeusStatusStripModel {
    /// The Skip link's title.
    public static let skipTitle = "Skip"

    /// Waiting on open questions: "? Waiting for your answer · Go to question · Skip", or "? 2 questions · Go to oldest · Skip".
    /// Pass `skippable: false` when the oldest open item is a Terminal prompt card (Zeus never dismisses those).
    public static func waiting(questions: Int, skippable: Bool = true, buttons: [Item] = []) -> Self {
        let several = questions > 1
        return .init(glyph: .question, sentence: several ? "\(questions) questions" : "Waiting for your answer",
                     actionTitle: several ? "Go to oldest" : "Go to question", skipTitle: skippable ? skipTitle : nil, buttons: buttons)
    }

    /// Unseen messages: "! Unread · Show", or "! 3 unread · Show".
    public static func unread(_ count: Int, buttons: [Item] = []) -> Self {
        .init(glyph: .alert, sentence: count > 1 ? "\(count) unread" : "Unread", actionTitle: "Show", buttons: buttons)
    }

    /// A managed session blocked on its own prompt: "! Waiting for you in Terminal · Open", or, when the prompt is mirrored
    /// as a card, "! Waiting for your answer · Go to prompt". Never with Skip.
    public static func blocked(mirrored: Bool, buttons: [Item] = []) -> Self {
        .init(glyph: .alert, sentence: mirrored ? "Waiting for your answer" : "Waiting for you in Terminal",
              actionTitle: mirrored ? "Go to prompt" : "Open", buttons: buttons)
    }

    /// Thinking or working: the activity row's own text, e.g. "Claude is working on tests". The jump scrolls to the bottom.
    public static func activity(_ text: String, buttons: [Item] = []) -> Self {
        .init(sentence: text, actionTitle: nil, buttons: buttons)
    }

    /// A message that couldn't be delivered: "Message not delivered · Show".
    public static func notDelivered(buttons: [Item] = []) -> Self {
        .init(sentence: "Message not delivered", actionTitle: "Show", buttons: buttons)
    }

    /// Quiet hours: "Quiet until 8:00". `time` is already formatted in the user's locale.
    public static func quiet(until time: String, buttons: [Item] = []) -> Self {
        .init(sentence: "Quiet until \(time)", isQuiet: true, buttons: buttons)
    }

    /// Nothing going on: "Idle", in secondary text.
    public static func idle(buttons: [Item] = []) -> Self {
        .init(sentence: "Idle", isQuiet: true, buttons: buttons)
    }

    /// The right-side buttons for a session: Terminal when there's a terminal target, New Conversation for a managed
    /// session, then Clear and Settings.
    public static func buttons(hasTerminal: Bool, isManaged: Bool, canClear: Bool = true) -> [Item] {
        var items: [Item] = []
        if hasTerminal { items.append(.init(.terminal)) }
        if isManaged { items.append(.init(.newConversation)) }
        items.append(.init(.clear, isEnabled: canClear))
        items.append(.init(.settings))
        return items
    }
}

// MARK: - View

/// The one-line status strip between the thread and the composer (CONVERSATION.md §15). 24 pt tall, a 1-px `divider`
/// rule below and none above, caption font, theme colours only.
///
/// The sentence and its link are one button (the jump; ⌘J in the app); Skip is a second link. When `actionTitle` is nil
/// and the state still has a target (working: scroll to the bottom), pass `onJump` and the sentence itself is the button.
public struct ZeusStatusStrip: View {
    public var model: ZeusStatusStripModel
    public var onJump: (() -> Void)?
    public var onSkip: (() -> Void)?
    public var onButton: (ZeusStatusStripModel.Button) -> Void
    @Environment(\.zeusPalette) private var palette
    @Environment(\.zeusFontChoice) private var fontChoice
    @Environment(\.zeusFontScale) private var fontScale

    /// The strip's height, excluding its 1-px rule.
    public static let height: CGFloat = 24
    /// Caption line height plus fixed vertical padding; preserves the Default strip geometry.
    public static func height(for choice: ZeusFontChoice, scale: ZeusFontScale = .default) -> CGFloat {
        scale == .default ? height : max(height, ZeusFonts.lineHeight(.caption, choice: choice, scale: scale) + 4)
    }
    /// Icon size, in points (one icon pixel is one point).
    public static let iconSize: CGFloat = 12

    public init(_ model: ZeusStatusStripModel, onJump: (() -> Void)? = nil, onSkip: (() -> Void)? = nil,
                onButton: @escaping (ZeusStatusStripModel.Button) -> Void = { _ in }) {
        self.model = model
        self.onJump = onJump
        self.onSkip = onSkip
        self.onButton = onButton
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: ZeusTheme.Spacing.s) {
                status
                Spacer(minLength: ZeusTheme.Spacing.xs)
                HStack(spacing: ZeusTheme.Spacing.xxs) {
                    ForEach(model.buttons) { item in
                        StripIconButton(item: item) { onButton(item.button) }
                    }
                }
            }
            .zeusFont(.caption)
            .lineLimit(1)
            .frame(minHeight: Self.height(for: fontChoice, scale: fontScale))
            Rectangle().fill(palette.divider).frame(height: ZeusTheme.pixel).accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Status")
    }

    /// The full line when it fits; otherwise the link words drop and the sentence itself takes the link colour
    /// ("? Waiting for your answer · Skip"); only then does the sentence truncate.
    private var status: some View {
        ViewThatFits(in: .horizontal) {
            statusLine(showsAction: true).fixedSize()
            statusLine(showsAction: false).fixedSize()
            statusLine(showsAction: false)
        }
        .layoutPriority(1)
    }

    private func statusLine(showsAction: Bool) -> some View {
        HStack(spacing: ZeusTheme.Spacing.xs) {
            if let onJump, model.actionTitle != nil || !model.isQuiet {
                StripLink(accessibility: [model.spokenSentence, model.actionTitle].compactMap { $0 }.joined(separator: ". "), action: onJump) {
                    sentence(linked: true, showsAction: showsAction)
                }
            } else {
                sentence(linked: false, showsAction: showsAction)
                    .accessibilityElement(children: .ignore).accessibilityLabel(model.spokenSentence)
            }
            if let skip = model.skipTitle, let onSkip {
                Text("·").foregroundStyle(palette.secondaryText).accessibilityHidden(true)
                StripLink(accessibility: skip, action: onSkip) { Text(skip).foregroundStyle(palette.title) }
                    .fixedSize()
                    .help("Skip (⇧⌘J)")
                    .accessibilityHint("Command-Shift-J")
            }
        }
    }

    private func sentence(linked: Bool, showsAction: Bool) -> some View {
        let action = showsAction ? model.actionTitle : nil
        let sentenceColor = model.isQuiet ? palette.secondaryText
            : linked && action == nil && model.actionTitle != nil ? palette.title : palette.text
        return HStack(spacing: ZeusTheme.Spacing.xs) {
            if let glyph = model.glyph {
                Text(glyph.rawValue).foregroundStyle(palette.title)
            }
            Text(model.sentence).foregroundStyle(sentenceColor).truncationMode(.tail)
            if let action {
                Text("·").foregroundStyle(palette.secondaryText)
                Text(action).foregroundStyle(linked ? palette.title : palette.secondaryText).fixedSize()
            }
        }
    }
}

/// A plain text link with a 22-pt target and a 1-px focus-ring underline, like the thread's notice lines.
private struct StripLink<Label: View>: View {
    let accessibility: String
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @FocusState private var focused: Bool
    @Environment(\.zeusPalette) private var palette
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        SwiftUI.Button(action: action) {
            label()
                .overlay(alignment: .bottom) {
                    Rectangle().fill(focused ? palette.focusRing : .clear).frame(height: ZeusTheme.pixel).offset(y: ZeusTheme.pixel)
                }
                .frame(minHeight: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .focusable(enabled, interactions: .edit).focusEffectDisabled().focused($focused)
        .onKeyPress(keys: [.space, .return]) { press in
            guard enabled, press.modifiers.intersection([.command, .option, .control]).isEmpty else { return .ignored }
            action(); return .handled
        }
        .accessibilityLabel(accessibility)
    }
}

/// A 12-px pixel icon in a 22-pt target: secondary text at rest, the title colour on hover or focus, a 1-px focus ring.
private struct StripIconButton: View {
    let item: ZeusStatusStripModel.Item
    let action: () -> Void
    @State private var hovering = false
    @FocusState private var focused: Bool
    @Environment(\.zeusPalette) private var palette
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        SwiftUI.Button(action: action) {
            ZeusGlyph.GlyphShape(rows: item.button.rows, pixel: 1)
                .fill((hovering || focused) && item.isEnabled ? palette.title : palette.secondaryText)
                .frame(width: ZeusStatusStrip.iconSize, height: ZeusStatusStrip.iconSize)
                .frame(width: 22, height: 22)
                .overlay(Rectangle().strokeBorder(focused ? palette.focusRing : .clear, lineWidth: ZeusTheme.pixel))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .disabled(!item.isEnabled)
        .opacity(item.isEnabled ? 1 : 0.5)
        .focusable(enabled && item.isEnabled, interactions: .edit).focusEffectDisabled().focused($focused)
        .onKeyPress(keys: [.space, .return]) { press in
            guard enabled && item.isEnabled, press.modifiers.intersection([.command, .option, .control]).isEmpty else { return .ignored }
            action(); return .handled
        }
        .onHover { hovering = $0 }
        .help(item.button.title)
        .accessibilityLabel(item.button.title)
    }
}
