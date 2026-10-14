import SwiftUI
import Testing
@testable import ZeusDesign

/// D3-5: the Zeus pop-up picker that replaces stock pickers in Connect your own.
@MainActor
struct ZeusMenuPickerTests {
    static let choices = [
        ZeusChoice(id: "a", title: "Claude · Website"),
        ZeusChoice(id: "b", title: "Codex · Website · pane 3"),
        ZeusChoice(id: "c", title: "Claude · Notes", detail: "Offline", isEnabled: false),
    ]
    typealias Picker = ZeusMenuPicker<String>

    @Test func fieldShowsTheChosenTitle() {
        #expect(Picker.displayTitle(selection: "b", choices: Self.choices, noneTitle: nil, placeholder: "Choose…") == "Codex · Website · pane 3")
        #expect(Picker.showsChoice(selection: "b", choices: Self.choices, noneTitle: nil))
    }

    @Test func nilShowsTheNoneTitleAsAChoice() {
        #expect(Picker.displayTitle(selection: nil, choices: Self.choices, noneTitle: "Auto (newest)", placeholder: "Choose…") == "Auto (newest)")
        #expect(Picker.showsChoice(selection: nil, choices: Self.choices, noneTitle: "Auto (newest)"))
    }

    @Test func nilWithoutNoneTitleIsAPrompt() {
        #expect(Picker.displayTitle(selection: nil, choices: Self.choices, noneTitle: nil, placeholder: "Choose a pane") == "Choose a pane")
        #expect(!Picker.showsChoice(selection: nil, choices: Self.choices, noneTitle: nil))
    }

    /// A saved ID that's no longer listed never shows a stale title; the caller adds an "· offline" choice if it wants one.
    @Test func unknownSelectionFallsBackToThePlaceholder() {
        #expect(Picker.displayTitle(selection: "zzz", choices: Self.choices, noneTitle: "Auto (newest)", placeholder: "Choose…") == "Choose…")
        #expect(!Picker.showsChoice(selection: "zzz", choices: Self.choices, noneTitle: "Auto (newest)"))
    }

    @Test func pixelFontCoversTheChrome() {
        #expect(ZeusFonts.pixelFontMissingGlyphs(in: "Choose… Auto (newest) · pane 3").isEmpty)
    }

    @Test func rendersInEveryPalette() {
        for scheme in [ColorScheme.light, .dark] {
            let view = Picker("Assistant session", choices: Self.choices, selection: .constant("a"), noneTitle: "Auto (newest)")
                .frame(width: 360).environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            #expect(renderer.cgImage != nil, "\(scheme)")
        }
    }
}
