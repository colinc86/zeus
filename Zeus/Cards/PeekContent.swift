import SwiftUI
import ZeusDesign
import ZeusProtocol

/// App-owned six-line peek presentation (CONTRACT §10.7), using ZeusDesign chrome and controls.
/// The shared ZeusPeekBubble still implements the earlier two/three-line design.
struct PeekContent: View {
    let card: Card
    let layout: PeekLayout
    let moreCount: Int
    let error: String?
    let answeredOptionID: String?
    let tail: ZeusDialogTail?
    let reveal: ZeusPeekBubble.Reveal
    var ratings: MessageRatingsModel? = nil
    var rate: () -> Void = {}
    var open: (PeekModel.OpenAction) -> Void = { _ in }
    var answer: (String) -> Void = { _ in }
    var close: () -> Void = {}
    @State private var hovering = false
    @Environment(\.zeusPalette) private var palette
    @Environment(\.zeusFontChoice) private var font
    @Environment(\.zeusAnimationsActive) private var animationsActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 4) {
            if PeekView.errorComesFirst(edge: tail?.edge ?? .bottom) { errorView }
            bubble
            if !PeekView.errorComesFirst(edge: tail?.edge ?? .bottom) { errorView }
        }
        // ZeusDialog's shadow is drawn outside its layout bounds.
        .padding(.trailing, ZeusTheme.pixel).padding(.bottom, ZeusTheme.pixel * 2)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var bubble: some View {
        let (inline, reply) = ZeusPeekBubble.layout(optionCount: card.options.count, acceptsText: card.input != nil)
        return VStack(alignment: .leading, spacing: ZeusTheme.Spacing.xs + ZeusTheme.pixel) {
            HStack(alignment: .firstTextBaseline, spacing: ZeusTheme.Spacing.xs) {
                if let title = card.title { Text(title).zeusFont(.button).foregroundStyle(palette.title).lineLimit(1) }
                Spacer(minLength: ZeusTheme.Spacing.xs)
                if let ratings, ratings.canRate(card) { MessageRatingButton(card: card, model: ratings, hovered: hovering, action: rate) }
                if moreCount > 0 {
                    Button("+\(moreCount) more") { open(.more) }
                        .buttonStyle(.plain).zeusFont(.badge).foregroundStyle(palette.onSecondary)
                        .padding(.horizontal, ZeusTheme.Spacing.xs).padding(.vertical, 1)
                        .background(PixelRoundedRectangle(steps: 1).fill(palette.secondaryFill))
                        .overlay(PixelRoundedRectangle(steps: 1).strokeBorder(palette.outline, lineWidth: ZeusTheme.pixel))
                        .fixedSize().accessibilityLabel("\(moreCount) more new messages")
                }
                Button(action: close) { ZeusGlyph(.close).padding(ZeusTheme.Spacing.xxs).contentShape(Rectangle()) }.buttonStyle(.plain).zeusFont(.caption)
                    .foregroundStyle(hovering ? palette.text : palette.secondaryText)
                    .fixedSize().help("Close").accessibilityLabel("Close")
            }
            typedBody.contentShape(Rectangle()).onTapGesture { open(.message) }
            if layout.showsMore {
                Button("More") { open(.message) }.buttonStyle(.plain).zeusFont(.caption)
                    .foregroundStyle(palette.title).accessibilityLabel("Read the full message")
            }
            if !card.attachments.isEmpty {
                Text(card.attachments.count == 1 ? "1 attachment" : "\(card.attachments.count) attachments")
                    .zeusFont(.caption).foregroundStyle(palette.secondaryText)
            }
            if inline > 0 || reply {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: ZeusTheme.Spacing.xs) { optionButtons(inline: inline, reply: reply) }
                    VStack(alignment: .leading, spacing: ZeusTheme.Spacing.xs) { optionButtons(inline: inline, reply: reply) }
                }
            }
        }
        .frame(width: layout.textWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .zeusDialog(tail: tail, padding: ZeusTheme.Spacing.s)
        .overlay {
            if hovering || card.priority == .high {
                PixelRoundedRectangle().inset(by: ZeusTheme.pixel).stroke(palette.accent, lineWidth: ZeusTheme.pixel)
                    .padding(tailInsets).allowsHitTesting(false)
            }
        }
        .onHover { hovering = $0 }
        .modifier(MessageRatingAccessibility(card: card, model: ratings))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.accessibilityDescription(card, choice: font, palette: palette))
        .accessibilityAction { open(.message) }
    }

    static func accessibilityDescription(_ card: Card, choice: ZeusFontChoice, palette: ZeusPalette) -> String {
        let body = ZeusMarkdown.attributed(card.body, choice: choice, palette: palette)
        let text = [card.title, ZeusMarkdown.spokenText(body)].compactMap { $0 }.joined(separator: ". ")
        return "\(ConversationLayout.speaker(card, sessions: [])) says: \(text)"
    }

    @ViewBuilder private func optionButtons(inline: Int, reply: Bool) -> some View {
        ForEach(card.options.prefix(inline), id: \.id) { option in
            Button {
                guard answeredOptionID == nil else { return }
                answer(option.id)
            } label: {
                HStack(spacing: ZeusTheme.Spacing.xs) {
                    if answeredOptionID == option.id { ZeusGlyph(.check) }
                    Text(option.label)
                }
            }
                .accessibilityLabel(option.label)
                .buttonStyle(ZeusButtonStyle(option.style, size: .small))
                .disabled(Self.optionDisabled(optionID: option.id, answeredOptionID: answeredOptionID))
        }
        if reply {
            Button(Self.secondaryActionLabel(card)) { open(card.input == nil ? .message : .reply) }
                .accessibilityLabel(Self.secondaryActionLabel(card))
                .buttonStyle(ZeusButtonStyle(.secondary, size: .small)).disabled(answeredOptionID != nil)
        }
    }

    static func secondaryActionLabel(_ card: Card) -> String { card.input == nil && card.options.count > 3 ? "Choose…" : "Reply…" }
    static func optionDisabled(optionID: String, answeredOptionID: String?) -> Bool {
        answeredOptionID != nil && answeredOptionID != optionID
    }

    private var typedBody: some View {
        let full = ZeusMarkdown.attributed(card.body, choice: font, palette: palette)
        return ZStack(alignment: .topLeading) {
            Text(full).lineLimit(layout.bodyLines).hidden()
            switch (reduceMotion || !animationsActive ? .full : reveal) {
            case .full: Text(full).lineLimit(layout.bodyLines)
            case .fraction(let fraction): revealed(full, fraction: fraction)
            case .typing(let start):
                let total = ZeusPeekTiming.typedLength(card.body)
                TimelineView(.explicit(ZeusPeekTiming.revealDates(start: start, total: total))) { context in
                    let count = ZeusPeekTiming.revealedCount(elapsed: context.date.timeIntervalSince(start), total: total)
                    revealed(full, fraction: total == 0 ? 1 : Double(count) / Double(total))
                }
            }
        }
        .zeusFont(.body).truncationMode(.tail).fixedSize(horizontal: false, vertical: true)
    }

    private func revealed(_ text: AttributedString, fraction: Double) -> some View {
        let count = Int((Double(text.characters.count) * min(max(fraction, 0), 1)).rounded(.down))
        let end = text.characters.index(text.startIndex, offsetBy: count)
        return Text(AttributedString(text[text.startIndex..<end])).lineLimit(layout.bodyLines)
    }

    @ViewBuilder private var errorView: some View {
        if let error {
            Text(error).zeusFont(.caption).foregroundStyle(palette.destructive)
                .fixedSize(horizontal: false, vertical: true).frame(width: layout.textWidth, alignment: .leading)
                .zeusDialog(padding: ZeusTheme.Spacing.s)
        }
    }

    private var tailInsets: EdgeInsets {
        let height = ZeusDialogTail.height
        switch tail?.edge {
        case .top?: return EdgeInsets(top: height, leading: 0, bottom: 0, trailing: 0)
        case .bottom?: return EdgeInsets(top: 0, leading: 0, bottom: height, trailing: 0)
        case .leading?: return EdgeInsets(top: 0, leading: height, bottom: 0, trailing: 0)
        case .trailing?: return EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: height)
        case nil: return EdgeInsets()
        }
    }
}
