import SwiftUI
import ZeusDesign

// TB1 integration placeholder; identical data/callback shape to the designer's component.
struct ZeusStatusStripModel: Equatable {
    enum Glyph: String { case question = "?", alert = "!" }
    enum Button: String, CaseIterable, Identifiable {
        case terminal, newConversation, clear, settings
        var id: String { rawValue }
        var title: String {
            switch self { case .terminal: "Open in Terminal"; case .newConversation: "Start a New Conversation…"; case .clear: "Clear Conversation…"; case .settings: "Assistant Settings…" }
        }
    }
    struct Item: Equatable, Identifiable {
        var button: Button
        var isEnabled: Bool
        var id: String { button.id }
        init(_ button: Button, isEnabled: Bool = true) { self.button = button; self.isEnabled = isEnabled }
    }
    var glyph: Glyph? = nil
    var sentence: String
    var actionTitle: String? = nil
    var skipTitle: String? = nil
    var isQuiet = false
    var buttons: [Item] = []
}

struct LocalStatusStrip: View {
    let model: ZeusStatusStripModel
    var onJump: (() -> Void)?
    var onSkip: (() -> Void)?
    var onButton: (ZeusStatusStripModel.Button) -> Void
    @Environment(\.zeusPalette) private var palette
    init(_ model: ZeusStatusStripModel, onJump: (() -> Void)? = nil, onSkip: (() -> Void)? = nil, onButton: @escaping (ZeusStatusStripModel.Button) -> Void) {
        self.model = model; self.onJump = onJump; self.onSkip = onSkip; self.onButton = onButton
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                if let onJump {
                    Button([model.glyph?.rawValue, model.sentence, model.actionTitle].compactMap { $0 }.joined(separator: " · "), action: onJump)
                        .buttonStyle(.plain).accessibilityLabel(model.sentence)
                } else { Text(model.sentence) }
                if let onSkip, let title = model.skipTitle { Button(title, action: onSkip).buttonStyle(.plain).accessibilityLabel(title) }
                Spacer(minLength: 0)
                ForEach(model.buttons) { item in
                    Button(item.button.title) { onButton(item.button) }.buttonStyle(.plain)
                        .disabled(!item.isEnabled).accessibilityLabel(item.button.title).help(item.button.title)
                }
            }.zeusFont(.caption).foregroundStyle(model.isQuiet ? palette.secondaryText : palette.text).lineLimit(1).frame(height: 24)
            Rectangle().fill(palette.divider).frame(height: 1)
        }
    }
}
