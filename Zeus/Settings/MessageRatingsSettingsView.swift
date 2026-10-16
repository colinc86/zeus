import SwiftUI
import ZeusDesign

struct MessageRatingsSettingsView: View {
    let model: MessageRatingsModel
    @Environment(\.zeusPalette) private var palette
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.ratings.contains { $0.scope == .kind } ? "What you hear about · \(model.ratings.filter { $0.scope == .kind }.count)" : "What you hear about").settingsTitle()
            if let provider = model.provider, !provider.mutedToday.isEmpty {
                HStack {
                    Text("Muted today: \(provider.mutedToday.count)").settingsCaption()
                    KeyboardButton("Show") { provider.showMuted() }.accessibilityLabel("Show today's muted messages")
                }
            }
            if !model.ratings.contains(where: { $0.scope == .kind }) {
                Text("Nothing rated yet. Hover a message your assistant sent on its own and click the rating button to say whether you want more of that kind, none, or only when you need to know.").settingsCaption()
            }
            ForEach(MessageRatingValue.allCases, id: \.self) { value in
                let group = model.ratings.filter { $0.rating == value && $0.scope == .kind }
                if !group.isEmpty {
                    Text(heading(value)).settingsBody()
                    ForEach(group) { rating in
                        MessageRatingSettingsRow(model: model, rating: rating).id(rating.id)
                    }
                }
            }
            ForEach(model.confirmations.keys.sorted(), id: \.self) { id in
                if !model.ratings.contains(where: { $0.id == id }), model.cards.card(id: id) == nil,
                   let confirmation = model.confirmations[id], model.canUndo(id) {
                    RatingConfirmationLine(text: confirmation.text, undo: { Task { await model.undo(id) } })
                    if let error = model.errors[id] { Text(error).settingsError() }
                }
            }
            Text("Your assistant gets each rating as a message and keeps the list in its folder as Zeus/preferences.md. Stopped kinds are held by Zeus even if your assistant still sends them.").settingsCaption()
            if let error = model.error { Text(error).settingsError() }
        }
    }
    private func heading(_ value: MessageRatingValue) -> String {
        switch value { case .up: "More like this"; case .neutral: "Need-to-know"; case .down: "Stopped" }
    }
}

private struct MessageRatingSettingsRow: View {
    let model: MessageRatingsModel
    let rating: MessageRating
    @State private var editing = false
    @State private var label = ""
    @FocusState private var labelFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if editing {
                HStack {
                    ZeusTextField("Kind label", text: $label).focused($labelFocused).accessibilityLabel("Kind label")
                        .onSubmit { save() }.onAppear { labelFocused = true }
                        .onExitCommand { editing = false }
                    KeyboardButton("Save", action: save).accessibilityLabel("Save kind label")
                    KeyboardButton("Cancel") { editing = false }.accessibilityLabel("Cancel editing kind label")
                }
            } else {
                HStack {
                    Text(rating.kindLabel).settingsBody()
                    Spacer()
                    KeyboardButton("Edit Label") { label = rating.kindLabel; editing = true; labelFocused = true }.accessibilityLabel("Edit label for \(rating.kindLabel)")
                    KeyboardButton("Remove") { Task { await model.remove(rating) } }.accessibilityLabel("Remove rating for \(rating.kindLabel)")
                }
            }
            Text("“" + String(rating.exampleText.prefix(80)) + (rating.exampleText.count > 80 ? "…" : "") + "”").settingsCaption()
            if rating.scope == .justThisOne { Text("Just this message").settingsCaption() }
            if let date = model.lastMatched(rating) {
                Text("Last matched \(date.formatted(.dateTime.weekday(.abbreviated).hour().minute()))").settingsCaption()
            } else { Text("Not seen since you rated it").settingsCaption() }
            MessageRatingSettingsSegments(selected: rating.rating) { value in Task { await model.update(rating, value: value) } }
            if let confirmation = model.confirmations[rating.id], model.canUndo(rating.id) {
                RatingConfirmationLine(text: confirmation.text, undo: { Task { await model.undo(rating.id) } })
            }
            if let error = model.errors[rating.id] { Text(error).settingsError() }
        }.padding(.bottom, 12).disabled(model.busy.contains(rating.id))
    }
    private func save() {
        Task {
            await model.update(rating, label: label)
            if model.errors[rating.id] == nil { editing = false }
        }
    }
}

/// Same tokens and spacing as SettingsSegments, with glyph labels for the outer stops.
private struct MessageRatingSettingsSegments: View {
    let selected: MessageRatingValue
    let choose: (MessageRatingValue) -> Void
    var body: some View {
        HStack(spacing: ZeusTheme.Spacing.s) {
            ForEach(MessageRatingValue.allCases, id: \.self) { value in
                KeyboardButton { choose(value) } label: {
                    Text(value == .up ? "More" : value == .down ? "Stop" : "Neutral")
                }.buttonStyle(ZeusButtonStyle(value == selected ? .primary : .secondary, size: .small))
                    .accessibilityLabel(value == .neutral ? "Only when I need to know" : MessageRatingsModel.label(value))
                    .accessibilityAddTraits(value == selected ? [.isSelected] : [])
            }
        }
    }
}
