import SwiftUI
import ZeusProtocol

// MARK: - Dialog

/// The card/dialog background: framed pixel panel, hard drop shadow, optional tail toward the avatar.
struct ZeusDialogModifier: ViewModifier {
    var tail: ZeusDialogTail?
    var padding: CGFloat
    @Environment(\.zeusPalette) private var palette
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let px = ZeusTheme.pixel
        content
            .foregroundStyle(palette.text)
            .padding(padding + ZeusTheme.borderWidth)
            .background {
                ZStack {
                    PixelRoundedRectangle().fill(palette.shadow).offset(x: px, y: px * 2)
                    PixelFrame(outline: palette.outline, frame: palette.frame,
                               fill: palette.panel.opacity(reduceTransparency || ZeusScrollExperiment.opaquePanel ? 1 : 0.97))
                }
            }
            .overlay(alignment: Self.overlayAlignment(tail?.edge)) {
                if let tail {
                    DialogTail(tail: tail, palette: palette)
                }
            }
            .padding(Self.paddingEdge(tail?.edge), tail == nil ? 0 : ZeusDialogTail.height)
    }

    nonisolated static func overlayAlignment(_ edge: ZeusDialogTail.Edge?) -> Alignment {
        switch edge {
        case .top?: .topLeading
        case .leading?: .topLeading
        case .trailing?: .topTrailing
        case .bottom?, nil: .bottomLeading
        }
    }

    nonisolated static func paddingEdge(_ edge: ZeusDialogTail.Edge?) -> Edge.Set {
        switch edge {
        case .top?: .top
        case .leading?: .leading
        case .trailing?: .trailing
        case .bottom?, nil: .bottom
        }
    }
}

/// The tail: outline, frame and panel-colored layers, the last one covering the panel's border
/// where they meet so the bubble reads as one shape.
private struct DialogTail: View {
    let tail: ZeusDialogTail
    let palette: ZeusPalette

    var body: some View {
        let px = ZeusTheme.pixel
        let rows = 5
        let width = CGFloat(rows + 1) * px * 2, height = CGFloat(rows + 1) * px
        switch tail.edge {
        case .top, .bottom:
            let up = tail.edge == .top
            layers(pointsUp: up, rows: rows)
                .offset(x: tail.offset - CGFloat(rows + 1) * px, y: up ? -(ZeusDialogTail.height - px) : ZeusDialogTail.height - px)
        case .leading, .trailing:
            // The downward tail turned 90°: rotation by quarter turns keeps every pixel on the grid.
            // Its visual box becomes height × width; overlap the panel border by 1 px, like the vertical tails.
            let leading = tail.edge == .leading
            let centerX = leading ? -(height / 2) + px : (height / 2) - px
            layers(pointsUp: false, rows: rows)
                .rotationEffect(.degrees(leading ? 90 : -90))
                .offset(x: (leading ? centerX - width / 2 : centerX + width / 2), y: tail.offset - height / 2)
        }
    }

    private func layers(pointsUp up: Bool, rows: Int) -> some View {
        let px = ZeusTheme.pixel
        return ZStack(alignment: up ? .bottom : .top) {
            PixelTailShape(rows: rows + 1, pointsUp: up).fill(palette.outline)
                .frame(width: CGFloat(rows + 1) * px * 2, height: CGFloat(rows + 1) * px)
            PixelTailShape(rows: rows, pointsUp: up).fill(palette.frame)
                .frame(width: CGFloat(rows) * px * 2, height: CGFloat(rows) * px)
            PixelTailShape(rows: rows - 1, pointsUp: up).fill(palette.panel)
                .frame(width: CGFloat(rows - 1) * px * 2, height: CGFloat(rows - 1) * px)
        }
        .accessibilityHidden(true)
    }
}

extension View {
    /// Wraps the view in the Zeus dialog box. With a `tail`, the panel gains a pointer toward the
    /// avatar and reserves `ZeusDialogTail.height` on that edge.
    public func zeusDialog(tail: ZeusDialogTail? = nil, padding: CGFloat = ZeusTheme.Spacing.m) -> some View {
        modifier(ZeusDialogModifier(tail: tail, padding: padding))
    }
}

// MARK: - Buttons

/// A pixel-framed button for card options. Primary is gold, secondary is quiet, destructive is red.
public struct ZeusButtonStyle: ButtonStyle {
    /// Button size: `.regular` for card options, `.small` for inline actions (attachment rows, pager).
    public enum Size: Sendable { case regular, small }

    public var style: CardOption.Style
    public var size: Size

    public init(_ style: CardOption.Style = .secondary, size: Size = .regular) {
        self.style = style
        self.size = size
    }

    public func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, style: style, size: size)
    }

    private struct StyledButton: View {
        let configuration: ButtonStyleConfiguration
        let style: CardOption.Style
        let size: Size
        @Environment(\.zeusPalette) private var palette
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let (fill, label): (Color, Color) = switch style {
            case .primary: (palette.accent, palette.onAccent)
            case .secondary: (palette.secondaryFill, palette.onSecondary)
            case .destructive: (palette.destructive, palette.onDestructive)
            }
            let px = ZeusTheme.pixel
            let pressed = configuration.isPressed
            configuration.label
                .zeusFont(size == .small ? .caption : .button)
                .lineLimit(1)
                .foregroundStyle(label)
                .padding(.horizontal, size == .small ? ZeusTheme.Spacing.s : ZeusTheme.Spacing.m)
                .padding(.vertical, size == .small ? ZeusTheme.Spacing.xxs + px : ZeusTheme.Spacing.xs + px)
                .background {
                    ZStack {
                        PixelRoundedRectangle(steps: 1).fill(palette.outline).offset(y: pressed ? 0 : px)
                        PixelFrame(outline: palette.outline, frame: nil, fill: pressed ? fill.mix(with: .black, by: 0.15) : fill, steps: 1)
                        // Top highlight: one light pixel row, the classic raised-button cue.
                        if !pressed {
                            Rectangle().fill(.white.opacity(0.28)).frame(height: px)
                                .padding(.horizontal, px * 2).padding(.top, px)
                                .frame(maxHeight: .infinity, alignment: .top)
                        }
                    }
                }
                .offset(y: pressed ? px : 0)
                .opacity(isEnabled ? 1 : 0.5)
                .contentShape(Rectangle())
        }
    }
}

// MARK: - Text field

/// The inset field chrome used by `ZeusTextFieldStyle` and `ZeusComposer`.
///
/// For multi-line input use `TextField(…, axis: .vertical)` inside it (or `ZeusComposer`). Don't overlay a
/// placeholder `Text` on a `TextEditor`: NSTextView's line-fragment padding and metrics put the overlay
/// visibly off the caret (the D5 bug; see CONVERSATION.md §5).
public struct ZeusFieldChrome<Content: View>: View {
    let content: Content
    var isFocused: Bool

    public init(isFocused: Bool = false, @ViewBuilder content: () -> Content) {
        self.content = content()
        self.isFocused = isFocused
    }

    public var body: some View {
        content.modifier(ZeusFieldChromeModifier(isFocused: isFocused))
    }
}

/// The field chrome as a modifier, so `ZeusTextFieldStyle` (whose `_body` is nonisolated) can apply it.
struct ZeusFieldChromeModifier: ViewModifier {
    /// Focused fields swap the inner frame to `focusRing` (the Zeus focus ring, at least 3:1 against the panel).
    var isFocused = false
    @Environment(\.zeusPalette) private var palette

    nonisolated init(isFocused: Bool = false) {
        self.isFocused = isFocused
    }

    func body(content: Content) -> some View {
        content
            .zeusFont(.body)
            .foregroundStyle(palette.text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, ZeusTheme.Spacing.s)
            .padding(.vertical, ZeusTheme.Spacing.xs + ZeusTheme.pixel)
            .background(PixelFrame(outline: palette.outline, frame: isFocused ? palette.focusRing : palette.fieldBorder,
                                   fill: palette.field, steps: 1))
    }
}

/// A text field inset in the dialog: dark well, pixel frame, Zeus body font.
public struct ZeusTextFieldStyle: TextFieldStyle {
    public init() {}

    public func _body(configuration: TextField<Self._Label>) -> some View {
        configuration.textFieldStyle(.plain).modifier(ZeusFieldChromeModifier())
    }
}

/// A one-line Zeus field whose placeholder is drawn in `secondaryText`, so an empty field never reads as a typed
/// value. `ZeusTextFieldStyle` alone can't do this: a style has no access to the prompt, and the platform draws
/// a plain placeholder only slightly lighter than the text (D3-7). `secure` makes it a password field.
/// The placeholder is also the VoiceOver label.
public struct ZeusTextField: View {
    public var placeholder: String
    @Binding public var text: String
    public var secure: Bool
    @Environment(\.zeusPalette) private var palette

    public init(_ placeholder: String, text: Binding<String>, secure: Bool = false) {
        self.placeholder = placeholder
        self._text = text
        self.secure = secure
    }

    public var body: some View {
        let prompt = Self.prompt(placeholder, palette: palette)
        Group {
            if secure { SecureField(placeholder, text: $text, prompt: prompt) }
            else { TextField(placeholder, text: $text, prompt: prompt) }
        }
        .textFieldStyle(ZeusTextFieldStyle())
    }

    /// The placeholder's color: secondary text, as the composer's placeholder (contrast-tested on `field`).
    nonisolated static func promptColor(_ palette: ZeusPalette) -> Color { palette.secondaryText }

    nonisolated static func prompt(_ placeholder: String, palette: ZeusPalette) -> Text {
        Text(placeholder).foregroundStyle(promptColor(palette))
    }
}

// MARK: - Progress

/// A segmented pixel progress bar. `value` is 0…1; `nil` shows an indeterminate marquee
/// (held still under Reduce Motion).
public struct ZeusProgressBar: View {
    public var value: Double?
    @Environment(\.zeusPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.zeusAnimationsActive) private var animationsActive

    /// Segment width and gap, in points.
    nonisolated static let segment: CGFloat = 6
    static let gap: CGFloat = ZeusTheme.pixel

    public init(value: Double?) {
        self.value = value
    }

    /// How many of `count` segments are lit for `value`.
    nonisolated static func litSegments(value: Double, count: Int) -> Int {
        guard value.isFinite else { return 0 }
        return Int((min(max(value, 0), 1) * Double(count)).rounded(.down))
    }

    public var body: some View {
        GeometryReader { geo in
            let inner = geo.size.width - ZeusTheme.borderWidth * 2
            let count = max(1, Int((inner + Self.gap) / (Self.segment + Self.gap)))
            Group {
                if let value {
                    segments(count: count, palette: palette) { $0 < Self.litSegments(value: value, count: count) }
                } else if reduceMotion || !animationsActive {
                    segments(count: count, palette: palette) { $0 % 3 == 0 }
                } else {
                    // 10 steps a second, only while the surface is visible.
                    TimelineView(.periodic(from: .distantPast, by: 0.1)) { context in
                        let head = Int(context.date.timeIntervalSinceReferenceDate * 10) % (count + 3)
                        segments(count: count, palette: palette) { $0 <= head && $0 > head - 3 }
                    }
                }
            }
            .padding(ZeusTheme.borderWidth)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
            .background(PixelFrame(outline: palette.outline, frame: nil, fill: palette.track, steps: 1))
        }
        .frame(height: 14)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue(value.map { "\(Int(($0 * 100).rounded())) percent" } ?? "In progress")
    }

    private func segments(count: Int, palette: ZeusPalette, lit: @escaping (Int) -> Bool) -> some View {
        HStack(spacing: Self.gap) {
            ForEach(0..<count, id: \.self) { i in
                Rectangle().fill(lit(i) ? palette.fill : palette.fill.opacity(0.14))
                    .frame(width: Self.segment)
            }
        }
    }
}

// MARK: - Attachment row

/// One attachment on a card: icon, label, a short target, and Open / Reveal actions.
/// Zeus never executes anything; the app opens targets via NSWorkspace (or the iOS equivalent).
public struct ZeusAttachmentRow: View {
    public var attachment: Attachment
    public var onOpen: () -> Void
    public var onReveal: (() -> Void)?
    @Environment(\.zeusPalette) private var palette

    /// The Finder button's label, the same words the app uses everywhere (D2-16, D3-10).
    public nonisolated static let revealLabel = "Show in Finder"

    /// - Parameter onReveal: "Show in Finder"; ignored for URLs. Pass `nil` to hide it (e.g. on iOS).
    public init(_ attachment: Attachment, onOpen: @escaping () -> Void, onReveal: (() -> Void)? = nil) {
        self.attachment = attachment
        self.onOpen = onOpen
        self.onReveal = onReveal
    }

    /// The SF Symbol for an attachment kind.
    nonisolated public static func symbol(for kind: Attachment.Kind) -> String {
        switch kind {
        case .file: "doc.fill"
        case .folder: "folder.fill"
        case .url: "link"
        }
    }

    /// A short form of the target: the file or folder name, or the URL's host.
    nonisolated public static func shortTarget(_ attachment: Attachment) -> String {
        switch attachment.kind {
        case .url:
            return URL(string: attachment.target)?.host() ?? attachment.target
        case .file, .folder:
            let name = (attachment.target as NSString).lastPathComponent
            return name.isEmpty ? attachment.target : name
        }
    }

    public var body: some View {
        HStack(spacing: ZeusTheme.Spacing.s) {
            Image(systemName: Self.symbol(for: attachment.kind))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.title)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(attachment.label).zeusFont(.body).foregroundStyle(palette.text).lineLimit(1)
                Text(Self.shortTarget(attachment)).zeusFont(.caption).foregroundStyle(palette.secondaryText)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: ZeusTheme.Spacing.xs)
            if let onReveal, attachment.kind != .url {
                Button(Self.revealLabel, action: onReveal).buttonStyle(ZeusButtonStyle(.secondary, size: .small))
            }
            Button("Open", action: onOpen).buttonStyle(ZeusButtonStyle(.primary, size: .small))
        }
        .padding(ZeusTheme.Spacing.xs + ZeusTheme.pixel)
        .background(PixelFrame(outline: palette.fieldBorder, frame: nil, fill: palette.field.opacity(0.55), steps: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(attachment.kind.rawValue): \(attachment.label)")
    }
}

// MARK: - Draft attachment chip

/// An attachment waiting in the composer before it's sent (dropped on Zeus, or added by Ask About This): icon, label,
/// an optional extra action and a pixel × that removes it. Lay several out with `ZeusChipFlow` so they wrap.
public struct ZeusAttachmentChip: View {
    public var attachment: Attachment
    public var actionTitle: String?
    public var onAction: (() -> Void)?
    public var onRemove: () -> Void
    /// A small preview drawn in place of the kind icon (Ask About This's Picture chip), at 32×20 pt.
    public var thumbnail: Image?
    @Environment(\.zeusPalette) private var palette

    /// The thumbnail's size, in points.
    public static let thumbnailSize = CGSize(width: 32, height: 20)

    /// - Parameters:
    ///   - thumbnail: a preview shown instead of the kind icon, for example the covered picture; `nil` for the icon.
    ///   - actionTitle: an extra button inside the chip, such as "Work in this folder"; `nil` for none.
    ///   - onRemove: removes the item from the draft. VoiceOver reads "Remove <label>".
    public init(_ attachment: Attachment, thumbnail: Image? = nil, actionTitle: String? = nil, onAction: (() -> Void)? = nil,
                onRemove: @escaping () -> Void) {
        self.attachment = attachment
        self.thumbnail = thumbnail
        self.actionTitle = actionTitle
        self.onAction = onAction
        self.onRemove = onRemove
    }

    /// What VoiceOver says for the × button.
    nonisolated public static func removeLabel(_ attachment: Attachment) -> String { "Remove \(attachment.label)" }

    public var body: some View {
        HStack(spacing: ZeusTheme.Spacing.xs) {
            if let thumbnail {
                thumbnail.resizable().interpolation(.medium).aspectRatio(contentMode: .fill)
                    .frame(width: Self.thumbnailSize.width, height: Self.thumbnailSize.height).clipped()
                    .overlay(Rectangle().strokeBorder(palette.outline, lineWidth: ZeusTheme.pixel))
                    .accessibilityHidden(true)
            } else {
                Image(systemName: ZeusAttachmentRow.symbol(for: attachment.kind))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.title)
                    .accessibilityHidden(true)
            }
            Text(attachment.label).zeusFont(.caption).foregroundStyle(palette.text)
                .lineLimit(1).truncationMode(.middle).frame(maxWidth: 180, alignment: .leading)
            if let actionTitle, let onAction {
                Button(actionTitle, action: onAction).buttonStyle(ZeusButtonStyle(.secondary, size: .small)).fixedSize()
            }
            Button(action: onRemove) {
                ZeusGlyph(.close).frame(width: 20, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(palette.secondaryText)
            .help("Remove")
            .accessibilityLabel(Self.removeLabel(attachment))
            .fixedSize()
        }
        .padding(.leading, ZeusTheme.Spacing.s).padding(.trailing, ZeusTheme.Spacing.xxs).padding(.vertical, ZeusTheme.Spacing.xxs)
        .background(PixelFrame(outline: palette.fieldBorder, frame: nil, fill: palette.field, steps: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(attachment.kind.rawValue): \(attachment.label)")
    }
}

/// Left-to-right chips that wrap onto new lines instead of scrolling sideways, so every attached item stays visible.
public struct ZeusChipFlow: Layout {
    public var spacing: CGFloat

    public init(spacing: CGFloat = ZeusTheme.Spacing.xs) { self.spacing = spacing }

    /// Which item indices go on each row, for item widths and the available width. An item wider than a row gets a
    /// row of its own.
    nonisolated public static func rows(widths: [CGFloat], maxWidth: CGFloat, spacing: CGFloat) -> [[Int]] {
        var rows: [[Int]] = []
        var current: [Int] = [], used: CGFloat = 0
        for (index, width) in widths.enumerated() {
            let needed = current.isEmpty ? width : used + spacing + width
            if !current.isEmpty && needed > maxWidth {
                rows.append(current); current = [index]; used = width
            } else {
                current.append(index); used = needed
            }
        }
        if !current.isEmpty { rows.append(current) }
        return rows
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let maxWidth = proposal.width ?? .infinity
        let rows = Self.rows(widths: sizes.map(\.width), maxWidth: maxWidth, spacing: spacing)
        var width: CGFloat = 0, height: CGFloat = 0
        for (number, row) in rows.enumerated() {
            var rowWidth: CGFloat = 0, rowHeight: CGFloat = 0
            for (position, index) in row.enumerated() {
                rowWidth += sizes[index].width + (position > 0 ? spacing : 0)
                rowHeight = max(rowHeight, sizes[index].height)
            }
            width = max(width, rowWidth)
            height += rowHeight + (number > 0 ? spacing : 0)
        }
        return CGSize(width: min(width, maxWidth), height: height)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        var y = bounds.minY
        for row in Self.rows(widths: sizes.map(\.width), maxWidth: bounds.width, spacing: spacing) {
            var x = bounds.minX
            let height = row.map { sizes[$0].height }.max() ?? 0
            for index in row {
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: min(sizes[index].width, bounds.width), height: sizes[index].height))
                x += sizes[index].width + spacing
            }
            y += height + spacing
        }
    }
}

// MARK: - Badge & pager

/// The open-card count badge shown on the avatar (CARDS.md §5).
public struct ZeusBadge: View {
    public var count: Int

    public init(count: Int) {
        self.count = count
    }

    /// The badge text: the count, capped at "9+".
    nonisolated public static func text(for count: Int) -> String { count > 9 ? "9+" : "\(max(count, 0))" }

    public var body: some View {
        let palette = ZeusPalette.dark  // the badge sits on the desktop, so it doesn't follow the scheme
        Text(Self.text(for: count))
            .zeusFont(.badge)
            .foregroundStyle(palette.onBadge)
            .padding(.horizontal, ZeusTheme.Spacing.xs + ZeusTheme.pixel)
            .padding(.vertical, ZeusTheme.pixel)
            .frame(minWidth: 18)
            .background(PixelFrame(outline: palette.outline, frame: nil, fill: palette.badge, steps: 1))
            .accessibilityLabel("\(count) open \(count == 1 ? "card" : "cards")")
    }
}

/// "◀ 1 of 3 ▶" (pixel glyphs) for paging through stacked cards.
public struct ZeusPager: View {
    public var index: Int
    public var count: Int
    public var onPrevious: () -> Void
    public var onNext: () -> Void
    @Environment(\.zeusPalette) private var palette

    /// - Parameter index: zero-based index of the visible card.
    public init(index: Int, count: Int, onPrevious: @escaping () -> Void, onNext: @escaping () -> Void) {
        self.index = index
        self.count = count
        self.onPrevious = onPrevious
        self.onNext = onNext
    }

    public var body: some View {
        HStack(spacing: ZeusTheme.Spacing.xs) {
            Button(action: onPrevious) { ZeusGlyph(.left) }
                .buttonStyle(.plain).disabled(index <= 0)
                .accessibilityLabel("Previous card")
            Text("\(index + 1) of \(count)").zeusFont(.caption).monospacedDigit()
            Button(action: onNext) { ZeusGlyph(.right) }
                .buttonStyle(.plain).disabled(index >= count - 1)
                .accessibilityLabel("Next card")
        }
        .foregroundStyle(palette.title)
    }
}

/// The avatar's "couldn't reach agent" marker (CARDS.md §5): a red "!" in the badge style
/// (outline + destructive fill). Like the badge it sits on the desktop, so it always uses the dark palette.
public struct ZeusWarningMarker: View {
    public init() {}

    public var body: some View {
        let palette = ZeusPalette.dark
        Text("!")
            .zeusFont(.badge)
            .foregroundStyle(palette.onBadge)
            .frame(minWidth: 18, minHeight: 18)
            .background(PixelFrame(outline: palette.outline, frame: nil, fill: palette.destructive, steps: 1))
            .accessibilityLabel("Couldn't reach the agent")
    }
}
