import AppKit

/// The panel dispatches document commands before the conversation's scroll keys.
enum DocumentKeyboard {
    enum Command: Equatable {
        case back, open, reveal, expand, find, previous, next, quote, source, zoom(Int)
    }
    @MainActor static func selectFindText(in root: NSView?) {
        guard let root else { return }
        if let field = root as? NSTextField, field.placeholderString == "Find" {
            field.selectText(nil)
            return
        }
        for child in root.subviews { selectFindText(in: child) }
    }
    static func command(_ event: NSEvent) -> Command? {
        command(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers ?? "", modifiers: event.modifierFlags)
    }
    static func command(keyCode: UInt16, characters: String, modifiers: NSEvent.ModifierFlags) -> Command? {
        let flags = modifiers.intersection([.command, .control, .option, .shift])
        if keyCode == 53 && flags.isEmpty { return .back }
        if flags == .command {
            switch characters.lowercased() {
            case "[": return .back
            case "o": return .open
            case "f": return .find
            case "=", "+": return .zoom(1)
            case "-": return .zoom(-1)
            case "0": return .zoom(0)
            default: break
            }
        }
        if flags == [.command, .shift] {
            switch characters.lowercased() {
            case "r": return .reveal
            case "'", "\"": return .quote
            case "+", "=": return .zoom(1)
            default: break
            }
        }
        if flags == [.command, .control] {
            if characters.lowercased() == "f" { return .expand }
            if keyCode == 123 { return .previous }
            if keyCode == 124 { return .next }
        }
        if flags == [.command, .option] && characters.lowercased() == "u" { return .source }
        return nil
    }
}
