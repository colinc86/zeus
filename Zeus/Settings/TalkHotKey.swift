import AppKit
import Carbon
import SwiftUI

/// A physical Carbon key and modifiers. Legacy letter-only preferences keep their original encoding until edited.
struct TalkHotKey: Codable, Equatable {
    var keyCode: UInt32 { didSet { legacyEncoding = false } }
    var command: Bool
    var option: Bool
    var control: Bool
    var shift: Bool
    var enabled: Bool
    private var legacyEncoding: Bool

    init(key: String = "Z", command: Bool = true, option: Bool = true, control: Bool = false, shift: Bool = false, enabled: Bool = true) {
        self.init(keyCode: Self.keys.first { $0.name.uppercased() == key.uppercased() }?.code ?? UInt32.max,
                  command: command, option: option, control: control, shift: shift, enabled: enabled)
        legacyEncoding = true
    }
    init(keyCode: UInt32, command: Bool = true, option: Bool = true, control: Bool = false, shift: Bool = false, enabled: Bool = true) {
        self.keyCode = keyCode; self.command = command; self.option = option; self.control = control
        self.shift = shift; self.enabled = enabled; legacyEncoding = false
    }
    var key: String { Self.keys.first { $0.code == keyCode }?.name ?? "None" }
    static let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ").map(String.init)
    var isFunctionKey: Bool { Self.keys.first { $0.code == keyCode }?.function == true }
    var validationError: String? {
        guard Self.keys.contains(where: { $0.code == keyCode }) else { return "Choose a keyboard key." }
        guard command || option || control || isFunctionKey else { return "Include Command, Option or Control." }
        if command && !option && !control && !shift && [kVK_ANSI_Q, kVK_ANSI_W, kVK_ANSI_Comma, kVK_Tab].contains(Int(keyCode)) {
            return "That shortcut is reserved by macOS or Zeus."
        }
        return nil
    }
    var isValid: Bool { validationError == nil }
    var displayName: String {
        (control ? "\u{2303}" : "") + (option ? "⌥" : "") + (shift ? "\u{21E7}" : "") + (command ? "⌘" : "") + key
    }
    /// Shift is added only when it creates a distinct shortcut. A shifted Talk key keeps its original action.
    var askAboutThis: TalkHotKey? {
        guard enabled, isValid, !shift else { return nil }
        var value = self; value.shift = true; return value
    }
    var menuKey: Character? { Self.keys.first { $0.code == keyCode }?.equivalent }
    var menuShortcut: KeyboardShortcut? {
        guard enabled, isValid, let menuKey else { return nil }
        return KeyboardShortcut(KeyEquivalent(menuKey), modifiers: eventModifiers)
    }
    var eventModifiers: SwiftUI.EventModifiers {
        var value: SwiftUI.EventModifiers = []
        if command { value.insert(.command) }; if option { value.insert(.option) }
        if control { value.insert(.control) }; if shift { value.insert(.shift) }
        return value
    }
    var modifiers: UInt32 { UInt32((command ? cmdKey : 0) | (option ? optionKey : 0) | (control ? controlKey : 0) | (shift ? shiftKey : 0)) }
    init(event: NSEvent) {
        let flags = event.modifierFlags
        self.init(keyCode: UInt32(event.keyCode), command: flags.contains(.command), option: flags.contains(.option),
                  control: flags.contains(.control), shift: flags.contains(.shift))
    }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.keyCode == rhs.keyCode && lhs.modifiers == rhs.modifiers && lhs.enabled == rhs.enabled
    }
    private enum CodingKeys: String, CodingKey { case key, keyCode, command, option, control, shift, enabled }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let code = try values.decodeIfPresent(UInt32.self, forKey: .keyCode)
        let letter = try values.decodeIfPresent(String.self, forKey: .key) ?? "Z"
        self.init(keyCode: code ?? Self.keys.first { $0.name == letter.uppercased() }?.code ?? UInt32.max,
                  command: try values.decode(Bool.self, forKey: .command), option: try values.decode(Bool.self, forKey: .option),
                  control: try values.decode(Bool.self, forKey: .control), shift: try values.decode(Bool.self, forKey: .shift),
                  enabled: try values.decode(Bool.self, forKey: .enabled))
        legacyEncoding = code == nil
    }
    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(key, forKey: .key)
        if !legacyEncoding { try values.encode(keyCode, forKey: .keyCode) }
        try values.encode(command, forKey: .command); try values.encode(option, forKey: .option)
        try values.encode(control, forKey: .control); try values.encode(shift, forKey: .shift); try values.encode(enabled, forKey: .enabled)
    }

    struct Key {
        let code: UInt32
        let name: String
        let equivalent: Character
        var function = false
    }
    /// Hardware codes are independent of modifiers; key equivalents use AppKit's special-key characters.
    // Special key symbols are system-font labels/menu equivalents, never pixel-font text.
    static let keys: [Key] = {
        var keys: [Key] = []
        let letters = [kVK_ANSI_A,kVK_ANSI_B,kVK_ANSI_C,kVK_ANSI_D,kVK_ANSI_E,kVK_ANSI_F,kVK_ANSI_G,kVK_ANSI_H,kVK_ANSI_I,kVK_ANSI_J,kVK_ANSI_K,kVK_ANSI_L,kVK_ANSI_M,kVK_ANSI_N,kVK_ANSI_O,kVK_ANSI_P,kVK_ANSI_Q,kVK_ANSI_R,kVK_ANSI_S,kVK_ANSI_T,kVK_ANSI_U,kVK_ANSI_V,kVK_ANSI_W,kVK_ANSI_X,kVK_ANSI_Y,kVK_ANSI_Z]
        for (name, code) in zip(Self.letters, letters) { keys.append(.init(code: UInt32(code), name: name, equivalent: Character(name.lowercased()))) }
        let digits = [kVK_ANSI_0,kVK_ANSI_1,kVK_ANSI_2,kVK_ANSI_3,kVK_ANSI_4,kVK_ANSI_5,kVK_ANSI_6,kVK_ANSI_7,kVK_ANSI_8,kVK_ANSI_9]
        for (index, code) in digits.enumerated() { keys.append(.init(code: UInt32(code), name: String(index), equivalent: Character(String(index)))) }
        let functions = [kVK_F1,kVK_F2,kVK_F3,kVK_F4,kVK_F5,kVK_F6,kVK_F7,kVK_F8,kVK_F9,kVK_F10,kVK_F11,kVK_F12,kVK_F13,kVK_F14,kVK_F15,kVK_F16,kVK_F17,kVK_F18,kVK_F19,kVK_F20]
        for (index, code) in functions.enumerated() { keys.append(.init(code: UInt32(code), name: "F\(index + 1)", equivalent: Character(UnicodeScalar(NSF1FunctionKey + index) ?? "\u{FFFD}"), function: true)) }
        let special: [(Int, String, String)] = [
            (kVK_ANSI_Equal,"=","="),(kVK_ANSI_Minus,"-","-"),(kVK_ANSI_LeftBracket,"[","["),(kVK_ANSI_RightBracket,"]","]"),
            (kVK_ANSI_Quote,"'","'"),(kVK_ANSI_Semicolon,";",";"),(kVK_ANSI_Backslash,"\\","\\"),(kVK_ANSI_Comma,",",","),
            (kVK_ANSI_Slash,"/","/"),(kVK_ANSI_Period,".","."),(kVK_ANSI_Grave,"`","`"),
            (kVK_Space,"Space"," "),(kVK_Return,"\u{21A9}","\r"),(kVK_Tab,"\u{21E5}","\t"),(kVK_Escape,"\u{238B}","\u{1B}"),(kVK_Delete,"\u{232B}","\u{8}"),
            (kVK_ForwardDelete,"\u{2326}",String(UnicodeScalar(NSDeleteFunctionKey) ?? "\u{FFFD}")),
            (kVK_LeftArrow,"←",String(UnicodeScalar(NSLeftArrowFunctionKey) ?? "\u{FFFD}")),(kVK_RightArrow,"→",String(UnicodeScalar(NSRightArrowFunctionKey) ?? "\u{FFFD}")),
            (kVK_UpArrow,"↑",String(UnicodeScalar(NSUpArrowFunctionKey) ?? "\u{FFFD}")),(kVK_DownArrow,"↓",String(UnicodeScalar(NSDownArrowFunctionKey) ?? "\u{FFFD}")),
            (kVK_Home,"↖",String(UnicodeScalar(NSHomeFunctionKey) ?? "\u{FFFD}")),(kVK_End,"↘",String(UnicodeScalar(NSEndFunctionKey) ?? "\u{FFFD}")),
            (kVK_PageUp,"\u{21DE}",String(UnicodeScalar(NSPageUpFunctionKey) ?? "\u{FFFD}")),(kVK_PageDown,"\u{21DF}",String(UnicodeScalar(NSPageDownFunctionKey) ?? "\u{FFFD}")),
            (kVK_ANSI_KeypadDecimal,"Keypad .","."),(kVK_ANSI_KeypadMultiply,"Keypad *","*"),(kVK_ANSI_KeypadPlus,"Keypad +","+"),
            (kVK_ANSI_KeypadClear,"Keypad Clear",String(UnicodeScalar(NSClearLineFunctionKey) ?? "\u{FFFD}")),(kVK_ANSI_KeypadDivide,"Keypad /","/"),
            (kVK_ANSI_KeypadEnter,"Keypad \u{21A9}","\u{3}"),(kVK_ANSI_KeypadMinus,"Keypad -","-"),(kVK_ANSI_KeypadEquals,"Keypad =","="),
            (kVK_ISO_Section,"§","§"),(kVK_JIS_Yen,"¥","¥"),(kVK_JIS_Underscore,"_","_"),(kVK_JIS_KeypadComma,"Keypad ,",","),
            (kVK_JIS_Eisu,"Eisu","\u{82F1}"),(kVK_JIS_Kana,"Kana","\u{304B}\u{306A}")]
        for (code, name, equivalent) in special { if let character = equivalent.first { keys.append(.init(code: UInt32(code), name: name, equivalent: character)) } }
        let keypad = [kVK_ANSI_Keypad0,kVK_ANSI_Keypad1,kVK_ANSI_Keypad2,kVK_ANSI_Keypad3,kVK_ANSI_Keypad4,kVK_ANSI_Keypad5,kVK_ANSI_Keypad6,kVK_ANSI_Keypad7,kVK_ANSI_Keypad8,kVK_ANSI_Keypad9]
        for (index, code) in keypad.enumerated() { keys.append(.init(code: UInt32(code), name: "Keypad \(index)", equivalent: Character(String(index)))) }
        return keys
    }()
}
