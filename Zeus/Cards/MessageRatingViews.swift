import SwiftUI
import ZeusDesign
import ZeusProtocol

struct MessageRatingButton: View {
    let card: Card
    let model: MessageRatingsModel
    var hovered: Bool
    var showAtRest = false
    var action: (() -> Void)? = nil
    @FocusState private var focused: Bool
    @State private var glyphHovered = false
    @Environment(\.zeusPalette) private var palette
    var body: some View {
        Button { if let action { action() } else { model.toggle(card) } } label: {
            MessageRatingAffordance(visible: hovered || focused || showAtRest || model.drafts[card.id] != nil,
                highlighted: glyphHovered || focused || model.drafts[card.id] != nil, focused: focused)
        }
        .buttonStyle(.plain).focusable(false).focusable(!model.busy.contains(card.id), interactions: .edit)
        .focusEffectDisabled().focused($focused).onHover { glyphHovered = $0 }
        .onKeyPress(keys: [.space, .return]) { press in
            guard press.modifiers.intersection([.command, .option, .control]).isEmpty else { return .ignored }
            if let action { action() } else { model.toggle(card) }; return .handled
        }
        .onChange(of: focused) { _, value in model.noteKeyboardFocus(cardID: card.id, focused: value) }
        .onDisappear { model.noteKeyboardFocus(cardID: card.id, focused: false) }
        .help("Rate this kind of message (⌘R)").accessibilityLabel("Rate this kind of message (⌘R)")
        .disabled(model.busy.contains(card.id))
    }
}

/// Shared drawing for native interaction and deterministic appearance fixtures.
struct MessageRatingAffordance: View {
    let visible: Bool
    let highlighted: Bool
    let focused: Bool
    @Environment(\.zeusPalette) private var palette
    var body: some View {
        ZeusGlyph(.more).foregroundStyle(highlighted ? palette.title : palette.secondaryText)
            .opacity(visible ? 1 : 0).frame(width: 22, height: 22).contentShape(Rectangle())
            .overlay {
                if focused { PixelRoundedRectangle(steps: 1).stroke(palette.focusRing, lineWidth: ZeusTheme.pixel).padding(ZeusTheme.pixel / 2) }
            }
    }
}

enum MessageRatingFocus: Hashable { case choice(MessageRatingValue), edit, scope, remove }

struct MessageRatingChoices: View {
    var selected: MessageRatingValue? = nil
    var focusRequest: UInt64 = 0
    let choose: (MessageRatingValue) -> Void
    let focus: FocusState<MessageRatingFocus?>.Binding
    var body: some View {
        ZeusFlowLayout(spacing: 6) {
            ForEach(MessageRatingValue.allCases, id: \.self) { value in
                if selected == value {
                    ZeusOptionButtons([.init(id: value.rawValue, label: MessageRatingsModel.label(value))], state: .answered(optionID: value.rawValue)) { _ in }
                } else {
                    KeyboardButton { choose(value) } label: {
                        HStack(spacing: 4) {
                            Text(MessageRatingsModel.label(value))
                        }
                    }.buttonStyle(ZeusButtonStyle(.secondary, size: .small)).focused(focus, equals: .choice(value))
                        .accessibilityLabel(MessageRatingsModel.label(value))
                        .help(value == .neutral ? "Only when I need to know" : MessageRatingsModel.label(value))
                        .accessibilityHint(value == .neutral ? "Only when I need to know" : "")

                }
            }
        }
        .onAppear { if focusRequest > 0 { focus.wrappedValue = MessageRatingValue.allCases.first { $0 != selected }.map(MessageRatingFocus.choice) } }
        .onChange(of: focusRequest) { focus.wrappedValue = MessageRatingValue.allCases.first { $0 != selected }.map(MessageRatingFocus.choice) }
    }
}

struct MessageRatingInline: View {
    let card: Card
    let model: MessageRatingsModel
    @FocusState private var labelFocused: Bool
    @FocusState private var controlFocused: MessageRatingFocus?
    @Environment(\.zeusPalette) private var palette
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let draft = model.drafts[card.id] {
                Rectangle().fill(palette.fieldBorder).frame(height: 1).accessibilityHidden(true)
                MessageRatingChoices(selected: selected(draft), focusRequest: model.focusRequest, choose: { value in Task { await model.rate(value, card: card) } }, focus: $controlFocused)
                if draft.editingLabel {
                    ZeusTextField("Kind of message", text: Binding(get: { model.drafts[card.id]?.label ?? "" }, set: { model.setLabel($0, id: card.id) }))
                        .focused($labelFocused).onSubmit { finishEditing(cancel: false) }
                        .onExitCommand { finishEditing(cancel: true) }
                        .accessibilityLabel("Kind of message").onAppear {
                            controlFocused = nil
                            Task { @MainActor in await Task.yield(); labelFocused = true }
                        }
                } else {
                    ZeusFlowLayout(spacing: 4) {
                        Text(draft.scope == .kind ? "For all “\(draft.label)”" : "For this message only").foregroundStyle(palette.secondaryText)
                        if draft.scope == .kind {
                            separator
                            link("Edit", target: .edit, label: "Edit the kind label") { controlFocused = nil; model.editLabel(card.id) }
                            separator
                            link("Just this one", target: .scope, label: "Rate this message only") { model.setScope(.justThisOne, id: card.id) }
                        } else { separator; link("All of this kind", target: .scope) { model.setScope(.kind, id: card.id) } }
                        if let current = model.currentRating(card) {
                            separator
                            link("Remove rating", target: .remove) { Task { await model.remove(current); if model.errors[current.id] == nil { model.cancel(card.id) } } }
                        }
                    }.zeusFont(.caption)
                }
            } else if let confirmation = model.confirmation(for: card) {
                RatingConfirmationLine(text: confirmation.text, undo: undoAction(confirmation))
            }
            if let error = model.errors[card.id] ?? model.currentRating(card).flatMap({ model.errors[$0.id] }) { Text(error).zeusFont(.caption).foregroundStyle(palette.destructive) }
        }
        .disabled(model.busy.contains(card.id))
        .onChange(of: controlFocused) { _, value in model.noteKeyboardFocus(cardID: card.id, focused: value != nil) }
        .onChange(of: labelFocused) { _, value in model.noteKeyboardFocus(cardID: card.id, focused: value) }
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            guard let draft = model.drafts[card.id], !draft.editingLabel, let focused = controlFocused else { return .ignored }
            let controls = MessageRatingValue.allCases.filter { $0 != selected(draft) }.map(MessageRatingFocus.choice)
                + (draft.scope == .kind ? [.edit, .scope] : [.scope])
                + (model.currentRating(card) == nil ? [] : [.remove])
            guard let index = controls.firstIndex(of: focused) else { return .ignored }
            let delta = press.key == .leftArrow || press.key == .upArrow ? -1 : 1
            controlFocused = controls[(index + delta + controls.count) % controls.count]; return .handled
        }
        .onKeyPress(.escape) {
            guard let draft = model.drafts[card.id] else { return .ignored }
            if draft.editingLabel { finishEditing(cancel: true) } else { model.cancel(card.id) }
            return .handled
        }
    }
    private func finishEditing(cancel: Bool) {
        model.finishLabel(card.id, cancel: cancel)
        labelFocused = false
        Task { @MainActor in await Task.yield(); controlFocused = .edit }
    }
    private var separator: some View { Text("·").foregroundStyle(palette.secondaryText).accessibilityHidden(true) }
    private func selected(_ draft: MessageRatingsModel.Draft) -> MessageRatingValue? {
        guard let rating = model.currentRating(card), rating.scope == draft.scope, rating.kindLabel == draft.label else { return nil }
        return rating.rating
    }
    private func undoAction(_ confirmation: MessageRatingsModel.Confirmation) -> (@MainActor @Sendable () -> Void)? {
        guard confirmation.receipt != nil else { return nil }
        return { Task { await model.undo(card.id) } }
    }
    private func link(_ text: String, target: MessageRatingFocus, label: String? = nil, action: @escaping @MainActor @Sendable () -> Void) -> some View {
        KeyboardButton(text, action: action).buttonStyle(.plain).foregroundStyle(palette.title)
            .accessibilityLabel(label ?? text).frame(minHeight: 22).focused($controlFocused, equals: target)
    }
}

struct RatingConfirmationLine: View {
    let text: String
    let undo: (@MainActor @Sendable () -> Void)?
    @Environment(\.zeusPalette) private var palette
    var body: some View {
        ZeusFlowLayout(spacing: 4) {
            Text(text).zeusFont(.caption).foregroundStyle(palette.secondaryText)
            if let undo {
                Text("·").zeusFont(.caption).foregroundStyle(palette.secondaryText).accessibilityHidden(true)
                KeyboardButton("Undo", action: undo).buttonStyle(.plain).zeusFont(.caption).foregroundStyle(palette.title).accessibilityLabel("Undo rating").frame(minHeight: 22)
            }
        }
    }
}

struct MessageRatingAccessibility: ViewModifier {
    let card: Card
    let model: MessageRatingsModel?
    func body(content: Content) -> some View {
        if let model, model.canRate(card) {
            content
                .accessibilityAction(named: "Rate: more like this") { model.begin(card); Task { await model.rate(.up, card: card) } }
                .accessibilityAction(named: "Rate: only when I need to know") { model.begin(card); Task { await model.rate(.neutral, card: card) } }
                .accessibilityAction(named: "Rate: stop these") { model.begin(card); Task { await model.rate(.down, card: card) } }
                .accessibilityAction(named: "Rate this message only") { model.begin(card); model.setScope(.justThisOne, id: card.id) }
                .accessibilityAction(named: "Edit the kind label") { model.begin(card); model.editLabel(card.id) }
        } else { content }
    }
}
struct OptionalRatingAccessibility: ViewModifier {
    let card: Card?
    let model: MessageRatingsModel?
    func body(content: Content) -> some View {
        if let card { content.modifier(MessageRatingAccessibility(card: card, model: model)) }
        else { content }
    }
}
struct MutedMessageLine: View {
    let card: Card
    let model: MessageRatingsModel
    @Environment(\.zeusPalette) private var palette
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(model.isBudgetHeld(card) ? "Held: over today's limit" : "Muted: \(card.about ?? model.decision(card)?.kindLabel ?? "Message")").lineLimit(1)
                Text("·").accessibilityHidden(true)
                KeyboardButton(model.isCollapsed(card) ? "Show" : "Hide") { if model.isCollapsed(card) { model.show(card.id) } else { model.hide(card.id) } }.buttonStyle(.plain).foregroundStyle(palette.title).accessibilityLabel(model.isBudgetHeld(card) ? (model.isCollapsed(card) ? "Show held message" : "Hide held message") : (model.isCollapsed(card) ? "Show muted message" : "Hide muted message")).frame(minHeight: 22)
            }
            if model.isBudgetHeld(card), let error = model.errors[card.id] { Text(error).foregroundStyle(palette.destructive) }
        }.zeusFont(.caption).foregroundStyle(palette.secondaryText).accessibilityElement(children: .contain)
    }
}
struct MutedMessageReason: View {
    let card: Card
    let model: MessageRatingsModel
    @Environment(\.zeusPalette) private var palette
    var body: some View {
        if model.isBudgetHeld(card) {
            Text("Your assistant has sent 6 unprompted messages today. Ones marked high priority still come through.")
                .zeusFont(.caption).foregroundStyle(palette.secondaryText)
        } else if let decision = model.decision(card), decision.releasedAt == nil {
            ZeusFlowLayout(spacing: 4) {
                Text(decision.engine == "exact" ? "Stopped kind: \(decision.kindLabel)" : "Looks like \(decision.kindLabel)")
                    .foregroundStyle(palette.secondaryText)
                    .help(decision.engine == "exact" ? "Same label" : "Matched by \(decision.engine), \(decision.score.formatted(.number.precision(.fractionLength(2))))")
                Text("·").foregroundStyle(palette.secondaryText).accessibilityHidden(true)
                KeyboardButton("Not this kind") { Task { await model.correct(card) } }.accessibilityLabel("Not this kind")
                Text("·").foregroundStyle(palette.secondaryText).accessibilityHidden(true)
                KeyboardButton("Change rating") { model.changeRating(card) }.accessibilityLabel("Change rating")
            }.zeusFont(.caption).buttonStyle(.plain).foregroundStyle(palette.title).disabled(model.busy.contains(card.id))
        }
    }
}
