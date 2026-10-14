import AppKit
import SwiftUI

/// Exact modifiers keep Jump and Skip distinct, including while a text editor has focus.
struct ConversationStripKeys: NSViewRepresentable {
    var jump: () -> Void
    var skip: (() -> Void)?
    func makeNSView(context: Context) -> KeyView { KeyView() }
    func updateNSView(_ view: KeyView, context: Context) { view.jump = jump; view.skip = skip }

    final class KeyView: NSView {
        var jump: (() -> Void)?
        var skip: (() -> Void)?
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard event.type == .keyDown, event.charactersIgnoringModifiers?.lowercased() == "j" else { return false }
            let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            if modifiers == .command, let jump { jump(); return true }
            if modifiers == [.command, .shift], let skip { skip(); return true }
            return false
        }
    }
}
