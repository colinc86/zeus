import SwiftUI
import ZeusProtocol

// Building blocks for the conversation panel (CONTRACT §10, docs/design/CONVERSATION.md).
// The app owns the data and the scrolling thread; these views own the look and the keys.

// MARK: - Bubbles

/// Who a bubble belongs to.
public enum ZeusSpeaker: Sendable, Equatable {
    /// The agent: framed bubble, left-aligned.
    case agent
    /// The user: filled bubble, right-aligned.
    case user
}

/// A message bubble in the thread. Put a `ZeusBubbleHeader`, body text, `ZeusOptionButtons`,
/// `ZeusAttachmentRow`s or a `ZeusProgressRow` inside it.
public struct ZeusBubble<Content: View>: View {
    public var speaker: ZeusSpeaker
    public var isMuted: Bool
    public var isHighPriority: Bool
    public var maxWidth: CGFloat?
    let content: Content
    @Environment(\.zeusPalette) private var palette

    /// - Parameters:
    ///   - muted: the card was dismissed or expired. It stays readable but recedes, and its controls should be removed.
    ///   - highPriority: a gold frame in place of the light one (agent bubbles only).
    ///   - maxWidth: an optional outer bubble limit for a resizable panel. Nil retains the speaker's theme limit.
    public init(_ speaker: ZeusSpeaker, muted: Bool = false, highPriority: Bool = false, maxWidth: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.speaker = speaker
        self.isMuted = muted
        self.isHighPriority = highPriority
        self.maxWidth = maxWidth
        self.content = content()
    }

    public var body: some View {
        let agent = speaker == .agent
        VStack(alignment: .leading, spacing: ZeusTheme.Spacing.s) { content }
            .zeusFont(.body)
            .foregroundStyle(isMuted ? palette.mutedText : agent ? palette.text : palette.onUserBubble)
            .environment(\.zeusMuted, isMuted)
            .padding(.horizontal, ZeusTheme.Spacing.m)
            .padding(.vertical, ZeusTheme.Spacing.s + ZeusTheme.pixel)
            .background {
                if isMuted {
                    // Recede with color, not opacity, so the text keeps WCAG AA (Q2 DES-6): a flat bubble the
                    // color of the panel, a light outline and secondary text.
                    PixelFrame(outline: palette.fieldBorder, frame: nil, fill: palette.panel)
                } else if agent {
                    PixelFrame(outline: palette.outline, frame: isHighPriority ? palette.accent : palette.fieldBorder,
                               fill: palette.agentBubble)
                } else {
                    PixelFrame(outline: palette.outline, frame: nil, fill: palette.userBubble)
                }
            }
            .frame(maxWidth: maxWidth.flatMap { $0.isFinite && $0 > 0 ? max(1, $0.rounded()) : nil }
                ?? (agent ? ZeusTheme.Conversation.agentBubbleMaxWidth : ZeusTheme.Conversation.userBubbleMaxWidth),
                   alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: agent ? .leading : .trailing)
            .accessibilityElement(children: .contain)
    }
}

/// A bubble's first line: the title (gold), and on the right a short time or status.
public struct ZeusBubbleHeader: View {
    public var title: String?
    public var trailing: String?
    @Environment(\.zeusPalette) private var palette
    @Environment(\.zeusMuted) private var muted

    public init(title: String?, trailing: String? = nil) {
        self.title = title
        self.trailing = trailing
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: ZeusTheme.Spacing.s) {
            if let title { Text(title).zeusFont(.button).foregroundStyle(muted ? palette.mutedText : palette.title).lineLimit(2) }
            Spacer(minLength: 0)
            if let trailing { Text(trailing).zeusFont(.caption).foregroundStyle(palette.secondaryText).lineLimit(1) }
        }
    }
}

// MARK: - Options

/// The option buttons of a question bubble.
public struct ZeusOptionButtons: View {
    /// Whether the question can still be answered.
    public enum State: Sendable, Equatable {
        /// Live buttons. With `shortcuts`, each shows its ⌘1…⌘9 key (only on the newest open question).
        case open(shortcuts: Bool)
        /// Answered: only the chosen option remains, as a ✓ chip. `nil` when the answer was free text.
        case answered(optionID: String?)
        /// Dismissed or expired before an answer: options are hidden.
        case closed
    }

    public var options: [CardOption]
    public var state: State
    public var action: (CardOption) -> Void
    @Environment(\.zeusPalette) private var palette

    public init(_ options: [CardOption], state: State, action: @escaping (CardOption) -> Void) {
        self.options = options
        self.state = state
        self.action = action
    }

    /// How strongly the "⌘1" hint shows on its button: quieter than the label, still WCAG AA on every fill.
    nonisolated public static let shortcutOpacity = 0.85

    /// The shortcut label for the option at `index`, e.g. "⌘1"; options past the ninth have none.
    nonisolated public static func shortcutLabel(index: Int) -> String? {
        (0..<9).contains(index) ? "⌘\(index + 1)" : nil
    }

    public var body: some View {
        switch state {
        case .open(let shortcuts):
            ZeusFlowLayout(spacing: ZeusTheme.Spacing.s) {
                ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                    Button { action(option) } label: {
                        HStack(spacing: ZeusTheme.Spacing.xs) {
                            Text(option.label)
                            if shortcuts, let key = Self.shortcutLabel(index: index) {
                                Text(key).zeusFont(.badge).opacity(ZeusOptionButtons.shortcutOpacity)
                            }
                        }
                    }
                    .buttonStyle(ZeusButtonStyle(option.style))
                    .accessibilityHint(shortcuts ? (Self.shortcutLabel(index: index).map { "Shortcut \($0)" } ?? "") : "")
                }
            }
        case .answered(let id):
            if let option = options.first(where: { $0.id == id }) {
                HStack(spacing: ZeusTheme.Spacing.xs) {
                    ZeusGlyph(.check)
                    Text(option.label)
                }
                .zeusFont(.caption)
                .foregroundStyle(palette.onSecondary)
                .padding(.horizontal, ZeusTheme.Spacing.s)
                .padding(.vertical, ZeusTheme.pixel)
                .background(PixelFrame(outline: palette.outline, frame: nil, fill: palette.secondaryFill, steps: 1))
                .accessibilityLabel("Answered: \(option.label)")
            }
        case .closed:
            EmptyView()
        }
    }
}

/// Wraps children onto new rows when they don't fit, left to right.
public struct ZeusFlowLayout: Layout {
    public var spacing: CGFloat

    public init(spacing: CGFloat = ZeusTheme.Spacing.s) {
        self.spacing = spacing
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width, !row.indices.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

// MARK: - Progress, labels, dividers

/// A progress bar with its percentage, for progress bubbles (updated in place).
public struct ZeusProgressRow: View {
    public var value: Double?
    @Environment(\.zeusPalette) private var palette

    public init(value: Double?) {
        self.value = value
    }

    public var body: some View {
        HStack(spacing: ZeusTheme.Spacing.s) {
            ZeusProgressBar(value: value)
            if let value {
                Text("\(Int((min(max(value, 0), 1) * 100).rounded()))%")
                    .zeusFont(.caption).monospacedDigit().foregroundStyle(palette.secondaryText)
                    .frame(width: 36, alignment: .trailing)
            }
        }
    }
}

/// "■ Claude · Zeus": names the session agent bubbles came from. Shown only when more than one
/// session is in the thread, and only where the session changes (CONVERSATION.md §3).
public struct ZeusSessionLabel: View {
    public var text: String
    public var colorIndex: Int
    @Environment(\.zeusPalette) private var palette

    /// - Parameter colorIndex: use `ZeusSessionLabel.colorIndex(for: sessionKey)` so a session keeps its color.
    public init(_ text: String, colorIndex: Int) {
        self.text = text
        self.colorIndex = colorIndex
    }

    /// A stable color slot for a session key (FNV-1a; not `hashValue`, which changes per launch).
    nonisolated public static func colorIndex(for sessionKey: String, count: Int = 4) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in sessionKey.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3 }
        return Int(hash % UInt64(max(count, 1)))
    }

    public var body: some View {
        let colors = palette.sessionColors
        HStack(spacing: ZeusTheme.Spacing.xs) {
            Rectangle().fill(colors[((colorIndex % colors.count) + colors.count) % colors.count])
                .frame(width: ZeusTheme.pixel * 3, height: ZeusTheme.pixel * 3)
            Text(text).zeusFont(.caption).foregroundStyle(palette.secondaryText).lineLimit(1).truncationMode(.middle)
        }
        .accessibilityLabel("From \(text)")
    }
}

/// A centered time divider, e.g. "Today 9:41", between bubbles more than 10 minutes apart.
public struct ZeusThreadDivider: View {
    public var text: String
    @Environment(\.zeusPalette) private var palette

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        HStack(spacing: ZeusTheme.Spacing.s) {
            Rectangle().fill(palette.fieldBorder.opacity(0.6)).frame(height: ZeusTheme.pixel)
            Text(text).zeusFont(.caption).foregroundStyle(palette.secondaryText).fixedSize()
            Rectangle().fill(palette.fieldBorder.opacity(0.6)).frame(height: ZeusTheme.pixel)
        }
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Jump pills (JB1)

/// A floating pill over the thread that jumps to what the user hasn't seen: unread messages above, the newest
/// message below, or the next open question (CONVERSATION.md §20). The app decides when one shows and what its
/// click does; `ZeusJumpPillCluster` places one or two of them on an edge.
public struct ZeusJumpPill: View {
    /// Where the pill's target is, relative to the viewport.
    public enum Direction: Sendable, Equatable { case up, down }

    /// What the pill points at.
    public enum Kind: Sendable, Equatable {
        /// Unseen agent messages above the viewport; always points up.
        case unread(Int)
        /// The newest message, below; `newCount` is the unseen messages below the viewport (0 = "↓ Latest").
        case latest(newCount: Int)
        /// The next open question, in the shared strip cycle; `count` is every open question.
        case question(count: Int, direction: Direction)

        public var direction: Direction {
            switch self {
            case .unread: .up
            case .latest: .down
            case .question(_, let direction): direction
            }
        }

        /// Whether something new waits there, so the arrow and count take the title colour.
        public var isNew: Bool {
            switch self {
            case .unread, .question: true
            case .latest(let newCount): newCount > 0
            }
        }

        /// Stable `accessibilityIdentifier` for the jump button (the × is `Identifier.markRead`).
        public var identifier: String {
            switch self {
            case .unread: Identifier.unread
            case .latest: Identifier.latest
            case .question: Identifier.question
            }
        }
    }

    /// `accessibilityIdentifier`s of the pill's buttons, for the app's key loop and tests.
    public enum Identifier {
        public static let unread = "jump-unread"
        public static let markRead = "jump-mark-read"
        public static let latest = "jump-latest"
        public static let question = "jump-question"
    }

    public var kind: Kind
    /// The short label (§20.3): arrow and count only. The cluster sets it when two full pills don't fit.
    public var compact: Bool
    public var action: () -> Void
    /// Marks the unread messages above as seen; only the unread pill shows the ×.
    public var onMarkRead: (() -> Void)?

    @State private var hovering = false
    @State private var pressed = false
    @FocusState private var focused: Bool
    @Environment(\.zeusPalette) private var palette

    /// The pill's minimum height: the standard 22-pt target.
    public static let minHeight: CGFloat = 22
    /// VoiceOver label of the ×.
    public static let markReadLabel = "Mark unread messages as read"
    /// Tooltip of the ×.
    public static let markReadTooltip = "Mark as read"

    public init(_ kind: Kind, compact: Bool = false, onMarkRead: (() -> Void)? = nil, action: @escaping () -> Void) {
        self.kind = kind
        self.compact = compact
        self.onMarkRead = onMarkRead
        self.action = action
    }

    /// The label split into the mark (arrow, count and the question's "?") and the words after it, if any.
    nonisolated public static func parts(_ kind: Kind, compact: Bool = false) -> (mark: String, words: String?) {
        let arrow = kind.direction == .up ? "↑" : "↓"
        switch kind {
        case .unread(let count):
            return ("\(arrow) \(count)", compact ? nil : "unread")
        case .latest(let newCount):
            if newCount > 0 { return ("\(arrow) \(newCount)", compact ? nil : "new") }
            return (arrow, compact ? nil : "Latest")
        case .question(let count, _):
            if compact { return ("\(arrow) ?", nil) }
            return ("\(arrow) ?", count > 1 ? "\(count) questions" : "Question")
        }
    }

    /// The pill's text: "↑ 3 unread", "↓ 2 new", "↓ Latest", "↑ ? Question", "↓ ? 2 questions"; short: "↑ 3", "↓", "↑ ?".
    nonisolated public static func title(_ kind: Kind, compact: Bool = false) -> String {
        let (mark, words) = parts(kind, compact: compact)
        return words.map { "\(mark) \($0)" } ?? mark
    }

    /// VoiceOver label of the jump button; the same in both forms.
    nonisolated public static func accessibilityLabel(_ kind: Kind) -> String {
        switch kind {
        case .unread(let count): "Jump to \(count) unread \(count == 1 ? "message" : "messages")"
        case .latest(let newCount): newCount > 0 ? "\(newCount) new \(newCount == 1 ? "message" : "messages"). Jump to the newest message" : "Jump to the newest message"
        case .question(let count, _): count > 1 ? "Jump to the next of \(count) questions" : "Jump to the next question"
        }
    }

    /// Native tooltip of the jump button.
    nonisolated public static func tooltip(_ kind: Kind) -> String {
        switch kind {
        case .unread: "Jump to the oldest unread message"
        case .latest: "Jump to the newest message (⌘↓)"
        case .question(let count, _): count > 1 ? "\(count) questions · Jump to the next (⌘J)" : "Jump to the next question (⌘J)"
        }
    }

    public var body: some View {
        let px = ZeusTheme.pixel
        let (mark, words) = Self.parts(kind, compact: compact)
        HStack(spacing: 0) {
            PillButton(identifier: kind.identifier, label: Self.accessibilityLabel(kind), pressed: $pressed, focused: $focused, action: action) {
                HStack(spacing: ZeusTheme.Spacing.xs) {
                    Text(mark).foregroundStyle(kind.isNew ? palette.title : palette.secondaryText)
                    if let words { Text(words).foregroundStyle(kind.isNew ? palette.text : palette.secondaryText) }
                }
                .zeusFont(.caption).lineLimit(1).fixedSize()
                .padding(.horizontal, ZeusTheme.Spacing.s)
                .padding(.vertical, ZeusTheme.Spacing.xs + px)
                .frame(minHeight: Self.minHeight)
            }
            .help(Self.tooltip(kind))
            .accessibilityValue(kind.direction == .up ? "above" : "below")
            if let onMarkRead {
                Rectangle().fill(palette.divider).frame(width: px).padding(.vertical, ZeusTheme.Spacing.xs + px)
                MarkReadButton(action: onMarkRead)
            }
        }
        // The capsule is as tall as its button, never the overlay it floats in.
        .fixedSize()
        .background {
            ZStack {
                if !pressed {
                    PixelRoundedRectangle(steps: 1).fill(palette.shadow).offset(x: px, y: px * 2)
                }
                PixelFrame(outline: focused ? palette.focusRing : palette.outline, frame: nil,
                           fill: hovering ? palette.field : palette.panel, steps: 1)
            }
        }
        .offset(y: pressed ? px : 0)
        .onHover { hovering = $0 }
    }

    /// The jump button: plain, focusable by Tab without the system's Keyboard Navigation setting, Return/Space activate.
    private struct PillButton<Label: View>: View {
        let identifier: String
        let label: String
        @Binding var pressed: Bool
        /// The pill's focus state, so the capsule draws the ring when its button is focused.
        var focused: FocusState<Bool>.Binding
        let action: () -> Void
        @ViewBuilder let content: () -> Label
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            SwiftUI.Button(action: action) { content().contentShape(Rectangle()) }
                .buttonStyle(PressReporting(pressed: $pressed))
                .focusable(false)
                .focusable(enabled, interactions: .edit).focusEffectDisabled().focused(focused)
                .onKeyPress(keys: [.space, .return]) { press in
                    guard enabled, press.modifiers.intersection([.command, .option, .control]).isEmpty else { return .ignored }
                    action(); return .handled
                }
                .accessibilityLabel(label)
                .accessibilityIdentifier(identifier)
        }
    }

    /// The ×: its own 22-pt target and focus stop inside the capsule; never jumps.
    private struct MarkReadButton: View {
        let action: () -> Void
        @State private var hovering = false
        @FocusState private var focused: Bool
        @Environment(\.zeusPalette) private var palette
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            SwiftUI.Button(action: action) {
                ZeusGlyph.GlyphShape(rows: ZeusGlyph.Symbol.close.rows, pixel: 1)
                    .fill(hovering || focused ? palette.title : palette.secondaryText)
                    .frame(width: 7, height: 7)
                    .frame(width: ZeusJumpPill.minHeight, height: ZeusJumpPill.minHeight)
                    .overlay(Rectangle().strokeBorder(focused ? palette.focusRing : .clear, lineWidth: ZeusTheme.pixel))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .focusable(enabled, interactions: .edit).focusEffectDisabled().focused($focused)
            .onKeyPress(keys: [.space, .return]) { press in
                guard enabled, press.modifiers.intersection([.command, .option, .control]).isEmpty else { return .ignored }
                action(); return .handled
            }
            .onHover { hovering = $0 }
            .help(ZeusJumpPill.markReadTooltip)
            .accessibilityLabel(ZeusJumpPill.markReadLabel)
            .accessibilityIdentifier(ZeusJumpPill.Identifier.markRead)
        }
    }

    /// A plain style that tells the pill when its button is pressed, so the whole capsule drops onto its shadow.
    private struct PressReporting: ButtonStyle {
        @Binding var pressed: Bool
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .onChange(of: configuration.isPressed) { _, now in pressed = now }
        }
    }
}

/// One or two jump pills on an edge of the thread (CONVERSATION.md §20.2): side by side, centered, the unread or
/// latest pill first and the question pill second. When two full pills don't fit the width, both go short.
/// Place it in `.overlay(alignment: .top)` or `.bottom` on the thread, and show or hide it with `transition`.
public struct ZeusJumpPillCluster: View {
    /// A pill and what its buttons do.
    public struct Item: Identifiable {
        public var kind: ZeusJumpPill.Kind
        public var action: () -> Void
        public var onMarkRead: (() -> Void)?
        public var id: String { kind.identifier }

        public init(_ kind: ZeusJumpPill.Kind, onMarkRead: (() -> Void)? = nil, action: @escaping () -> Void) {
            self.kind = kind
            self.onMarkRead = onMarkRead
            self.action = action
        }
    }

    /// The thread edge the cluster hugs; it decides which way the pills slide in.
    public enum Edge: Sendable, Equatable { case top, bottom }

    public var edge: Edge
    public var items: [Item]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.zeusAnimationsActive) private var animationsActive

    /// Fade and slide length, in seconds.
    public static let duration: TimeInterval = 0.12
    /// How far a cluster slides in from its edge, in points.
    public static let slide: CGFloat = 4
    /// The width the pills keep clear on each side of the thread before the short labels kick in.
    public static let margin: CGFloat = ZeusTheme.Spacing.m

    public init(edge: Edge, items: [Item]) {
        self.edge = edge
        self.items = items
    }

    /// The cluster's enter and exit: a fade with a 4-pt slide from its edge, opacity only under Reduce Motion,
    /// nothing while the surface's animations are paused.
    public static func transition(edge: Edge, reduceMotion: Bool, animationsActive: Bool = true) -> AnyTransition {
        guard animationsActive else { return .identity }
        let fade = AnyTransition.opacity.animation(.easeOut(duration: duration))
        if reduceMotion { return fade }
        return .offset(y: edge == .top ? -slide : slide).combined(with: fade)
    }

    /// The transition for the current environment, for a caller that already reads it.
    public var transition: AnyTransition {
        Self.transition(edge: edge, reduceMotion: reduceMotion, animationsActive: animationsActive)
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            row(compact: false)
            if items.count > 1 { row(compact: true) }
        }
        .padding(.horizontal, Self.margin)
        .padding(edge == .top ? .top : .bottom, ZeusTheme.Spacing.xs)
        .animation(reduceMotion || !animationsActive ? nil : .easeOut(duration: Self.duration), value: items.map(\.id))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(edge == .top ? "Jump up" : "Jump down")
    }

    private func row(compact: Bool) -> some View {
        HStack(spacing: ZeusTheme.Spacing.xs) {
            ForEach(items) { item in
                ZeusJumpPill(item.kind, compact: compact, onMarkRead: item.onMarkRead, action: item.action)
            }
        }
    }
}

/// The live line above the composer while the agent is thinking or working:
/// "• • •  Drafting your Q3 talk  40%". Driven by the avatar state and `zeus_set_status` detail/progress.
public struct ZeusActivityRow: View {
    public var text: String
    public var progress: Double?
    @Environment(\.zeusPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.zeusAnimationsActive) private var animationsActive

    public init(_ text: String, progress: Double? = nil) {
        self.text = text
        self.progress = progress
    }

    public var body: some View {
        HStack(spacing: ZeusTheme.Spacing.s) {
            Group {
                if animationsActive && !reduceMotion {
                    // 0.3 s steps, only while the surface is visible.
                    TimelineView(.periodic(from: .distantPast, by: Self.dotInterval)) { context in
                        dots(lit: Self.litDots(at: context.date), palette: palette)
                    }
                } else {
                    dots(lit: 3, palette: palette)
                }
            }
            .accessibilityHidden(true)
            Text(text).zeusFont(.caption).foregroundStyle(palette.secondaryText).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            if let progress {
                Text("\(Int((min(max(progress, 0), 1) * 100).rounded()))%").zeusFont(.caption).monospacedDigit()
                    .foregroundStyle(palette.secondaryText)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

extension ZeusActivityRow {
    nonisolated static let dotInterval: TimeInterval = 0.3

    /// How many of the three dots are lit at `date` (0–3, cycling every 1.2 s).
    nonisolated static func litDots(at date: Date) -> Int {
        Int((date.timeIntervalSinceReferenceDate / dotInterval).rounded(.down)) % 4
    }

    func dots(lit: Int, palette: ZeusPalette) -> some View {
        HStack(spacing: ZeusTheme.pixel * 2) {
            ForEach(0..<3, id: \.self) { i in
                Rectangle().fill(palette.title.opacity(i < lit ? 1 : 0.3))
                    .frame(width: ZeusTheme.pixel * 2, height: ZeusTheme.pixel * 2)
            }
        }
    }
}

/// The empty thread: a friendly line, or a nudge to connect an assistant.
public struct ZeusEmptyThread: View {
    public var assistantName: String?
    public var onOpenSettings: (() -> Void)?
    @Environment(\.zeusPalette) private var palette

    /// - Parameter assistantName: `nil` when no assistant session is connected.
    public init(assistantName: String?, onOpenSettings: (() -> Void)? = nil) {
        self.assistantName = assistantName
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        VStack(spacing: ZeusTheme.Spacing.s) {
            if let assistantName {
                Text("Nothing here yet.").zeusFont(.button).foregroundStyle(palette.title)
                Text("Type below to message \(assistantName). Updates and questions will show up here.")
            } else {
                Text("No assistant connected").zeusFont(.button).foregroundStyle(palette.title)
                Text("Start your agent with Zeus enabled to chat here.")
                if let onOpenSettings {
                    Button("Open Settings", action: onOpenSettings).buttonStyle(ZeusButtonStyle(.secondary, size: .small))
                }
            }
        }
        .zeusFont(.caption)
        .foregroundStyle(palette.secondaryText)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 260)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Composer

/// "↩ Replying to: <title>  ✕" (pixel glyphs): shown above the composer when sending will answer a question.
public struct ZeusReplyChip: View {
    public var title: String
    public var onClear: () -> Void
    @Environment(\.zeusPalette) private var palette

    public init(title: String, onClear: @escaping () -> Void) {
        self.title = title
        self.onClear = onClear
    }

    public var body: some View {
        HStack(spacing: ZeusTheme.Spacing.xs) {
            Rectangle().fill(palette.accent).frame(width: ZeusTheme.pixel * 2)
            ZeusGlyph(.reply).foregroundStyle(palette.secondaryText)
            Text("Replying to:").foregroundStyle(palette.secondaryText)
            Text(title).foregroundStyle(palette.text).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: ZeusTheme.Spacing.xs)
            Button(action: onClear) { ZeusGlyph(.close).padding(ZeusTheme.Spacing.xxs).contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .foregroundStyle(palette.secondaryText)
                .help("Send as a new message instead (⌘K)")
                .accessibilityLabel("Stop replying to \(title)")
        }
        .zeusFont(.caption)
        .padding(.trailing, ZeusTheme.Spacing.s)
        .padding(.vertical, ZeusTheme.pixel)
        .fixedSize(horizontal: false, vertical: true)
        .background(palette.field.opacity(0.6))
    }
}

/// The always-present composer at the bottom of the conversation panel.
///
/// Keys (while the field is focused): Return sends · ⇧Return inserts a new line ·
/// Backspace in an empty field clears the reply chip · ⌘K clears the reply chip.
/// The placeholder is the text field's own prompt, so it always sits exactly where the
/// cursor and typed text do (the D5 alignment fix; see `ZeusComposerAlignmentTests`).
/// Taking focus never selects a restored draft: the caret goes to the end, so typing adds to it.
public struct ZeusComposer: View {
    @Binding var text: String
    public var placeholder: String
    public var replyingTo: String?
    public var isSending: Bool
    /// Allows an attachment-only draft; text and attachments share the same Send action.
    public var hasAttachments: Bool
    var focus: FocusState<Bool>.Binding
    public var onClearReply: () -> Void
    public var onSend: () -> Void
    @State private var selection: TextSelection?
    @Environment(\.zeusPalette) private var palette

    /// - Parameters:
    ///   - replyingTo: the title of the question that sending will answer, or `nil` for a plain message.
    ///   - focus: bind to the panel's focus state; the app focuses the composer whenever the panel opens.
    ///   - hasAttachments: enables Send for an attachment-only draft without changing the composer layout.
    ///   - onSend: called with text or attachments. The app clears the draft once the send is accepted.
    public init(text: Binding<String>, placeholder: String, replyingTo: String? = nil, isSending: Bool = false, hasAttachments: Bool = false,
                focus: FocusState<Bool>.Binding, onClearReply: @escaping () -> Void, onSend: @escaping () -> Void) {
        self._text = text
        self.placeholder = placeholder
        self.replyingTo = replyingTo
        self.isSending = isSending
        self.hasAttachments = hasAttachments
        self.focus = focus
        self.onClearReply = onClearReply
        self.onSend = onSend
    }

    /// Whether text or attachments can be sent; never while already sending.
    nonisolated public static func canSend(_ text: String, isSending: Bool, hasAttachments: Bool = false) -> Bool {
        !isSending && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hasAttachments)
    }

    /// Inserts a newline at `selection` (or at the end), returning the new text and caret position.
    nonisolated static func insertingNewline(into text: String, at selection: Range<String.Index>?) -> (String, String.Index) {
        var result = text
        let range = selection ?? result.endIndex..<result.endIndex
        let offset = result.distance(from: result.startIndex, to: range.lowerBound)
        result.replaceSubrange(range, with: "\n")
        return (result, result.index(result.startIndex, offsetBy: offset + 1))
    }

    /// Whether `selection` is the select-all AppKit applies when the field takes focus (or no selection yet).
    nonisolated static func selectsAll(_ selection: TextSelection?, of text: String) -> Bool {
        guard let selection else { return true }
        guard case .selection(let range) = selection.indices else { return false }
        return range.lowerBound == text.startIndex && range.upperBound == text.endIndex && !range.isEmpty
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ZeusTheme.Spacing.xs) {
            if let replyingTo { ZeusReplyChip(title: replyingTo, onClear: onClearReply) }
            HStack(alignment: .bottom, spacing: ZeusTheme.Spacing.s) {
                ZeusFieldChrome(isFocused: focus.wrappedValue) {
                    TextField("", text: $text, selection: $selection,
                              prompt: Text(placeholder).foregroundStyle(palette.secondaryText), axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(ZeusTheme.Conversation.composerLines)
                        // Report the wrapped, line-capped ideal height even while the native panel
                        // still has its previous height. Otherwise its fixed thread compresses us,
                        // and the app measures that compressed height instead of resizing.
                        .fixedSize(horizontal: false, vertical: true)
                        .focused(focus)
                        .disabled(isSending)
                        .onKeyPress(.return, phases: .down) { press in handleReturn(press) }
                        // Backspace arrives as U+007F on macOS and as `.delete` (U+0008) elsewhere.
                        .onKeyPress(keys: [.delete, KeyEquivalent("\u{7F}")], phases: .down) { _ in
                            guard text.isEmpty, replyingTo != nil else { return .ignored }
                            onClearReply()
                            return .handled
                        }
                        .accessibilityLabel(replyingTo.map { "Reply to \($0)" } ?? "Message")
                        .onChange(of: focus.wrappedValue) { _, focused in
                            // AppKit selects the whole field when it takes focus, so a restored draft would be
                            // replaced by the next keystroke. Focus has settled by now: put the caret at the end.
                            // A click that placed the caret leaves a partial selection, which is kept.
                            if focused, Self.selectsAll(selection, of: text) { selection = TextSelection(insertionPoint: text.endIndex) }
                        }
                }
                Button(action: send) {
                    ZeusGlyph(.up).padding(.vertical, ZeusTheme.Spacing.xxs)
                }
                .buttonStyle(ZeusButtonStyle(.primary))
                .disabled(!Self.canSend(text, isSending: isSending, hasAttachments: hasAttachments))
                .help("Send (Return)")
                .accessibilityLabel("Send")
            }
        }
        .background {
            // ⌘K clears the reply chip; a hidden button so the shortcut works wherever focus is in the panel.
            Button("", action: onClearReply).keyboardShortcut("k", modifiers: .command)
                .opacity(0).allowsHitTesting(false).accessibilityHidden(true)
                .disabled(replyingTo == nil)
        }
    }

    private func handleReturn(_ press: KeyPress) -> KeyPress.Result {
        if press.modifiers.contains(.shift) || press.modifiers.contains(.option) {
            let range: Range<String.Index>? = if case .selection(let r)? = selection?.indices { r } else { nil }
            let (updated, caret) = Self.insertingNewline(into: text, at: range)
            text = updated
            selection = TextSelection(insertionPoint: caret)
            return .handled
        }
        guard press.modifiers.subtracting(.command).isEmpty else { return .ignored }
        send()
        return .handled
    }

    private func send() {
        guard Self.canSend(text, isSending: isSending, hasAttachments: hasAttachments) else { return }
        onSend()
    }
}

// MARK: - Warning popover

/// Content for the delivery-warning popover (CONTRACT §10.6). The app presents it with
/// `.popover` anchored to the avatar's warning marker.
public struct ZeusWarningPopover: View {
    public var title: String
    public var message: String
    public var footnote: String?
    /// The gold default button, or `nil` when no action can help (A4D-5): then Discard… is the only button.
    public var primary: PrimaryAction?
    public var onDiscard: () -> Void
    @State private var confirmingDiscard = false
    @Environment(\.zeusPalette) private var palette

    /// Button labels, in title case like every other app-authored button (D3-10).
    public enum Labels {
        public static let retry = "Retry Now"
        public static let discard = "Discard…"
        public static let confirmDiscard = "Discard Them"
        public static let keep = "Keep"
        /// The primary action when the managed assistant is stopped or never ran (A4D-5, A4D-9).
        public static let startAssistant = ZeusManagedPresentation.Action.start.menuTitle
        /// The primary action when the managed conversation can't be resumed (A4D-6).
        public static let startNewConversation = ZeusManagedPresentation.Action.newConversation.title
    }

    /// The popover's primary button: what fixes the problem, e.g. Retry Now or Start Assistant.
    public struct PrimaryAction {
        public var title: String
        public var action: () -> Void
        /// - Parameters:
        ///   - title: a title-case button label, such as `Labels.retry` or `Labels.startAssistant`.
        public init(_ title: String, action: @escaping () -> Void) {
            self.title = title
            self.action = action
        }
        /// Retry Now, for deliveries Zeus can actually attempt again.
        public static func retry(_ action: @escaping () -> Void) -> Self { .init(Labels.retry, action: action) }
    }

    /// - Parameters:
    ///   - message: what happened, e.g. "2 replies couldn't reach Claude (~/Zeus), disconnected 6 min ago."
    ///   - footnote: what happens if the user does nothing, e.g. "They'll be sent when it reconnects."
    public init(title: String = "Couldn't reach your assistant", message: String, footnote: String? = nil,
                onRetry: @escaping () -> Void, onDiscard: @escaping () -> Void) {
        self.init(title: title, message: message, footnote: footnote, primary: .retry(onRetry), onDiscard: onDiscard)
    }

    /// - Parameters:
    ///   - primary: the button that fixes the problem, or `nil` to hide it when nothing can help (an assistant
    ///     that isn't connected can't be retried). Discard… and its confirmation are always there.
    public init(title: String = "Couldn't reach your assistant", message: String, footnote: String? = nil,
                primary: PrimaryAction?, onDiscard: @escaping () -> Void) {
        self.title = title
        self.message = message
        self.footnote = footnote
        self.primary = primary
        self.onDiscard = onDiscard
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ZeusTheme.Spacing.s) {
            HStack(spacing: ZeusTheme.Spacing.xs) {
                Text("!").zeusFont(.badge).foregroundStyle(palette.onBadge)
                    .frame(width: 16, height: 16)
                    .background(PixelFrame(outline: palette.outline, frame: nil, fill: palette.destructive, steps: 1))
                Text(title).zeusFont(.button).foregroundStyle(palette.title)
            }
            Text(message).zeusFont(.body).fixedSize(horizontal: false, vertical: true)
            if let footnote {
                Text(footnote).zeusFont(.caption).foregroundStyle(palette.secondaryText).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: ZeusTheme.Spacing.s) {
                if confirmingDiscard {
                    Button(Labels.confirmDiscard, role: .destructive, action: onDiscard)
                        .buttonStyle(ZeusButtonStyle(.destructive))
                    Button(Labels.keep) { confirmingDiscard = false }
                        .buttonStyle(ZeusButtonStyle(.secondary))
                        .keyboardShortcut(.cancelAction)
                } else {
                    if let primary {
                        Button(primary.title, action: primary.action)
                            .buttonStyle(ZeusButtonStyle(.primary))
                            .keyboardShortcut(.defaultAction)
                    }
                    Button(Labels.discard) { confirmingDiscard = true }
                        .buttonStyle(ZeusButtonStyle(.secondary))
                }
            }
        }
        .frame(width: 272, alignment: .leading)
        .zeusDialog()
    }
}
