import Carbon
import Foundation
import SwiftUI

/// A physical letter key plus modifiers; no keyboard monitoring or Accessibility permission is needed.
struct TalkHotKey: Codable, Equatable {
    var key = "Z"
    var command = true
    var option = true
    var control = false
    var shift = false
    var enabled = true

    static let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ").map(String.init)
    var isValid: Bool { keyCode != nil && (command || option || control) }
    var displayName: String {
        [control ? "Control" : nil, option ? "Option" : nil, shift ? "Shift" : nil, command ? "Command" : nil, key]
            .compactMap { $0 }.joined(separator: " + ")
    }
    var menuShortcut: KeyboardShortcut? {
        guard enabled, isValid, let letter = key.lowercased().first else { return nil }
        return KeyboardShortcut(KeyEquivalent(letter), modifiers: eventModifiers)
    }
    var eventModifiers: SwiftUI.EventModifiers {
        var value: SwiftUI.EventModifiers = []
        if command { value.insert(.command) }; if option { value.insert(.option) }
        if control { value.insert(.control) }; if shift { value.insert(.shift) }
        return value
    }
    var modifiers: UInt32 {
        UInt32((command ? cmdKey : 0) | (option ? optionKey : 0) | (control ? controlKey : 0) | (shift ? shiftKey : 0))
    }
    var keyCode: UInt32? {
        let codes = [kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F,
                     kVK_ANSI_G, kVK_ANSI_H, kVK_ANSI_I, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L,
                     kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R,
                     kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U, kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X,
                     kVK_ANSI_Y, kVK_ANSI_Z]
        guard let index = Self.letters.firstIndex(of: key) else { return nil }
        return UInt32(codes[index])
    }
}
