import SwiftUI
import ZeusProtocol

/// Zeus "saying" a new message from his corner of the screen (CONTRACT §10.7, CONVERSATION.md §14).
/// A compact speech bubble: title, 2–3 lines with a typewriter reveal, up to 3 option buttons,
/// "Reply…", "+N more" and ✕. It never takes keyboard focus; the app shows it in a non-activating panel.
public struct ZeusPeekBubble: View {
    /// How much of the body is revealed.
    public enum Reveal: Sendable, Equatable {
        /// Fully shown (Reduce Motion, or after typing finishes).
        case full
        /// Typewriter from `start`, driven by a `TimelineView`; see `ZeusPeekTiming`.
        case typing(start: Date)
        /// A fixed fraction, for previews and renders.
        case fraction(Double)
    }

    public var title: String?
    public var message: String
    public var options: [CardOption]
    public var acceptsText: Bool
    public var attachmentCount: Int
    public var moreCount: Int
    public var isHighPriority: Bool
    public var tail: ZeusDialogTail?
    public var reveal: Reveal
    public var answeredOptionID: String?
    public var onOpen: () -> Void
    /// Opens the oldest unseen card from the more tag; nil uses onOpen.
    public var onMore: (() -> Void)?
    /// Expands a text reply with its chip selected; nil uses onOpen.
    public var onReply: (() -> Void)?
    public var onOption: (CardOption) -> Void
    public var onClose: () -> Void
    @State private var hovering = false
    @Environment(\.zeusPalette) private var palette
    @Environment(\.zeusFontChoice) private var fontChoice
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.zeusAnimationsActive) private var animationsActive

    /// - Parameters:
    ///   - body: the card's markdown body (inline markdown only).
    ///   - options: the card's options or actions. Up to 3 are shown as buttons; more turn into "Reply…".
    ///   - acceptsText: the card takes a free-text answer (`input != nil`); adds "Reply…".
    ///   - moreCount: other unseen cards that arrived while this one is showing ("+N more").
    ///   - answeredOptionID: set right after an option is clicked: that button shows "✓", the others disable,
    ///     and the app hides the bubble 0.6 s later (CONVERSATION.md §14.6).
    ///   - onOpen: open the conversation panel scrolled to this card (body click, "Reply…", "+N more").
    ///   - onOption: answer the card with this option directly, without expanding.
    ///   - onClose: the ✕ button.
    public init(title: String?, body: String, options: [CardOption] = [], acceptsText: Bool = false,
                attachmentCount: Int = 0, moreCount: Int = 0, highPriority: Bool = false,
                tail: ZeusDialogTail? = nil, reveal: Reveal = .full, answeredOptionID: String? = nil,
                onOpen: @escaping () -> Void, onMore: (() -> Void)? = nil, onReply: (() -> Void)? = nil, onOption: @escaping (CardOption) -> Void = { _ in },
                onClose: @escaping () -> Void) {
        self.title = title
        self.message = body
        self.options = options
        self.acceptsText = acceptsText
        self.attachmentCount = attachmentCount
        self.moreCount = moreCount
        self.isHighPriority = highPriority
        self.tail = tail
        self.reveal = reveal
        self.answeredOptionID = answeredOptionID
        self.onMore = onMore
        self.onReply = onReply
        self.onOpen = onOpen
        self.onOption = onOption
        self.onClose = onClose
    }

    /// The buttons a card gets in a peek bubble: up to 3 options inline, and "Reply…" when the card takes
    /// text or has more than 3 options (CONTRACT §10.7).
    nonisolated public static func layout(optionCount: Int, acceptsText: Bool) -> (inlineOptions: Int, showsReply: Bool) {
        optionCount > ZeusPeekTiming.maxInlineOptions
            ? (0, true)
            : (optionCount, acceptsText)
    }

    /// Body line limit: 3 lines, or 2 when buttons take the room.
    nonisolated public static func bodyLineLimit(hasButtons: Bool) -> Int { hasButtons ? 2 : 3 }

    public var body: some View {
        let (inline, reply) = Self.layout(optionCount: options.count, acceptsText: acceptsText)
        let hasButtons = inline > 0 || reply
        VStack(alignment: .leading, spacing: ZeusTheme.Spacing.xs + ZeusTheme.pixel) {
            HStack(alignment: .firstTextBaseline, spacing: ZeusTheme.Spacing.xs) {
                if let title { Text(title).zeusFont(.button).foregroundStyle(palette.title).lineLimit(1) }
                Spacer(minLength: ZeusTheme.Spacing.xs)
                if moreCount > 0 {
                    Button(action: onMore ?? onOpen) { Text("+\(moreCount) more") }
                        .buttonStyle(.plain)
                        .zeusFont(.badge)
                        .foregroundStyle(palette.onSecondary)
                        .padding(.horizontal, ZeusTheme.Spacing.xs)
                        .padding(.vertical, 1)
                        .background(PixelFrame(outline: palette.outline, frame: nil, fill: palette.secondaryFill, steps: 1))
                        .accessibilityLabel("\(moreCount) more new messages")
                }
                Button(action: onClose) { ZeusGlyph(.close).padding(ZeusTheme.Spacing.xxs).contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .zeusFont(.caption)
                    // Full-strength at rest (3:1 for a control); hover darkens it to the text color.
                    .foregroundStyle(hovering || isHighPriority ? palette.text : palette.secondaryText)
                    .help("Close")
                    .accessibilityLabel("Close")
            }
            typedBody(lineLimit: Self.bodyLineLimit(hasButtons: hasButtons))
                .contentShape(Rectangle())
                .onTapGesture(perform: onOpen)
            if attachmentCount > 0 {
                Text(attachmentCount == 1 ? "1 attachment" : "\(attachmentCount) attachments")
                    .zeusFont(.caption).foregroundStyle(palette.secondaryText)
            }
            if hasButtons {
                HStack(spacing: ZeusTheme.Spacing.xs) {
                    ForEach(options.prefix(inline), id: \.id) { option in
                        Button { onOption(option) } label: {
                            HStack(spacing: ZeusTheme.Spacing.xs) {
                                if answeredOptionID == option.id { ZeusGlyph(.check) }
                                Text(option.label)
                            }
                        }
                            .buttonStyle(ZeusButtonStyle(option.style, size: .small))
                    }
                    if reply {
                        Button("Reply…", action: onReply ?? onOpen).buttonStyle(ZeusButtonStyle(.secondary, size: .small))
                    }
                }
                .disabled(answeredOptionID != nil)
            }
        }
        .frame(minWidth: ZeusPeekTiming.minWidth - ZeusTheme.Spacing.s * 2 - ZeusTheme.borderWidth * 2,
               maxWidth: ZeusPeekTiming.maxWidth - ZeusTheme.Spacing.s * 2 - ZeusTheme.borderWidth * 2,
               alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .zeusDialog(tail: tail, padding: ZeusTheme.Spacing.s)
        .overlay {
            // Hover highlight: the frame warms to the accent (same cue as a focused field).
            if hovering || isHighPriority {
                PixelRoundedRectangle().inset(by: ZeusTheme.pixel).stroke(palette.accent, lineWidth: ZeusTheme.pixel)
                    .padding(Self.tailPadding(tail))
                    .allowsHitTesting(false)
            }
        }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.accessibilityText(title: title, message: message))
    }

    /// The bubble's VoiceOver label: the title and the message's readable text, never its markdown (A4N-5).
    nonisolated public static func accessibilityText(title: String?, message: String) -> String {
        "Zeus says: " + [title, ZeusMarkdown.spokenText(markdown: message)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ". ")
    }

    /// The bubble's inset from its frame, on the tail's edge.
    nonisolated static func tailPadding(_ tail: ZeusDialogTail?) -> EdgeInsets {
        guard let tail else { return EdgeInsets() }
        let h = ZeusDialogTail.height
        switch tail.edge {
        case .top: return EdgeInsets(top: h, leading: 0, bottom: 0, trailing: 0)
        case .bottom: return EdgeInsets(top: 0, leading: 0, bottom: h, trailing: 0)
        case .leading: return EdgeInsets(top: 0, leading: h, bottom: 0, trailing: 0)
        case .trailing: return EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: h)
        }
    }

    /// The full text is laid out invisibly so the bubble keeps its final size while the text types in.
    @ViewBuilder private func typedBody(lineLimit: Int) -> some View {
        let full = ZeusMarkdown.attributed(message, choice: fontChoice, palette: palette)
        ZStack(alignment: .topLeading) {
            Text(full).lineLimit(lineLimit).hidden()
            switch (reduceMotion || !animationsActive ? .full : reveal) {
            case .full:
                Text(full).lineLimit(lineLimit)
            case .fraction(let f):
                Text(Self.prefix(full, count: Int((Double(full.characters.count) * min(max(f, 0), 1)).rounded())))
                    .lineLimit(lineLimit)
            case .typing(let start):
                // One update per revealed character, and none after the last: a finished (or
                // long-lived, high-priority) bubble costs nothing (P8 #4).
                let total = ZeusPeekTiming.typedLength(message)
                TimelineView(.explicit(ZeusPeekTiming.revealDates(start: start, total: total))) { context in
                    let count = ZeusPeekTiming.revealedCount(elapsed: context.date.timeIntervalSince(start), total: total)
                    Text(Self.prefix(full, count: count)).lineLimit(lineLimit)
                }
            }
        }
        .zeusFont(.body)
        .truncationMode(.tail)
        .fixedSize(horizontal: false, vertical: true)
    }

    nonisolated static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    nonisolated static func prefix(_ text: AttributedString, count: Int) -> AttributedString {
        let n = max(0, min(count, text.characters.count))
        let end = text.characters.index(text.startIndex, offsetBy: n)
        return AttributedString(text[text.startIndex..<end])
    }
}

/// Peek-bubble timing and sizing. Pure functions, so the app can drive the avatar's `talking` state
/// from exactly the same numbers the bubble types with.
public enum ZeusPeekTiming {
    public static let minWidth: CGFloat = 200
    public static let maxWidth: CGFloat = 280
    public static let maxInlineOptions = 3
    /// Characters the typewriter shows: about 3 lines at the max width (≈ 31 characters a line).
    public static let typedCharacterCap = 100
    /// Base typing speed, and the longest a reveal may take: long text types faster rather than longer.
    public static let charactersPerSecond: Double = 40
    public static let maxTypingDuration: TimeInterval = 2.4
    /// Extra `talking` time after the last character, so the mouth closes on the final word.
    public static let talkTail: TimeInterval = 0.25
    /// Enter / exit animation durations (CONVERSATION.md §14.5).
    public static let enterDuration: TimeInterval = 0.16
    public static let exitDuration: TimeInterval = 0.12

    /// Number of characters the typewriter reveals (markdown syntax excluded), capped at what fits.
    public static func typedLength(_ markdownBody: String) -> Int {
        // The rendered characters (block markers included, syntax excluded); palette and font don't change them.
        let plain = ZeusMarkdown.attributed(markdownBody, choice: .pixel, palette: .light).characters
        return min(plain.count, typedCharacterCap)
    }

    /// How long the typewriter runs for `length` characters.
    public static func typingDuration(length: Int) -> TimeInterval {
        min(Double(max(length, 0)) / charactersPerSecond, maxTypingDuration)
    }

    /// Characters revealed `elapsed` seconds after typing starts.
    public static func revealedCount(elapsed: TimeInterval, total: Int) -> Int {
        guard total > 0 else { return 0 }
        let duration = typingDuration(length: total)
        guard duration > 0, elapsed < duration else { return total }
        return max(0, min(total, Int((elapsed / duration * Double(total)).rounded(.down))))
    }

    /// The moments the typewriter's visible character count changes: one date per character, ending at
    /// the last one. Drives `TimelineView(.explicit(_:))`, so updates stop once the text is complete.
    public static func revealDates(start: Date, total: Int) -> [Date] {
        guard total > 0 else { return [] }
        let duration = typingDuration(length: total)
        // A hair past each boundary so the floor in `revealedCount` has already ticked over.
        return (1...total).map { start.addingTimeInterval(Double($0) * duration / Double(total) + 0.0005) }
    }

    /// How long Zeus shows `talking` for a bubble: while it types, plus a short tail. With Reduce Motion
    /// the text appears at once; Zeus still says it for a beat (1.2 s) because talking is frame
    /// animation, not movement.
    public static func talkingDuration(length: Int, reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? 1.2 : typingDuration(length: length) + talkTail
    }

    /// CONTRACT §10.7 auto-hide: `clamp(4 + words/4, 6, 15)` seconds; `nil` for high priority (stays until used).
    public static func autoHideDelay(words: Int, highPriority: Bool) -> TimeInterval? {
        highPriority ? nil : min(max(4 + Double(words) / 4, 6), 15)
    }

    /// Word count used for auto-hide: title plus body.
    public static func wordCount(title: String?, body: String) -> Int {
        ((title ?? "") + " " + body).split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    /// After the pointer leaves a hovered bubble, at least this much time remains before it hides.
    public static let minimumAfterHover: TimeInterval = 2
}

extension AnyTransition {
    /// The peek bubble's entrance and exit: rise 4 pt toward its tail's opposite side and fade in
    /// (160 ms), fade out (120 ms). Reduce Motion: opacity only.
    @MainActor
    public static func zeusPeek(reduceMotion: Bool, edge: ZeusDialogTail.Edge = .bottom) -> AnyTransition {
        if reduceMotion { return .opacity.animation(.easeOut(duration: ZeusPeekTiming.enterDuration)) }
        let offset: CGSize = switch edge {
        case .bottom: CGSize(width: 0, height: 4)
        case .top: CGSize(width: 0, height: -4)
        case .leading: CGSize(width: -4, height: 0)
        case .trailing: CGSize(width: 4, height: 0)
        }
        return .asymmetric(
            insertion: .offset(offset).combined(with: .opacity).animation(.easeOut(duration: ZeusPeekTiming.enterDuration)),
            removal: .opacity.animation(.easeIn(duration: ZeusPeekTiming.exitDuration)))
    }
}
