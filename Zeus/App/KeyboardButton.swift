import SwiftUI
import ZeusDesign

/// One Tab stop even with macOS Keyboard Navigation enabled; always accepts Space and Return.
/// The inner Button retains its native accessibility action, while the wrapper owns keyboard focus.
struct KeyboardButton<Label: View>: View {
    let action: @MainActor () -> Void
    @ViewBuilder let label: () -> Label
    var focus: FocusState<Bool>.Binding? = nil
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var enabled
    @Environment(\.zeusPalette) private var palette

    var body: some View {
        Button(action: action, label: label)
            .focusable(false)
            .focusable(enabled, interactions: .edit)
            .focusEffectDisabled().focused(focus ?? $focused)
            .overlay {
                PixelRoundedRectangle(steps: 1).stroke((focus?.wrappedValue ?? focused) ? palette.focusRing : .clear, lineWidth: 1)
                    .padding(1).allowsHitTesting(false)
            }
            .onKeyPress(keys: [.space, .return]) { press in
                guard enabled, press.modifiers.intersection([.command, .option, .control]).isEmpty else { return .ignored }
                action(); return .handled
            }
    }
}

extension KeyboardButton where Label == Text {
    init(_ title: String, focus: FocusState<Bool>.Binding? = nil, action: @escaping @MainActor () -> Void) {
        self.action = action
        self.label = { Text(title) }
        self.focus = focus
    }
}
