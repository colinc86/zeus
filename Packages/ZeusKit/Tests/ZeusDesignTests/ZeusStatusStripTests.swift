import SwiftUI
import Testing
@testable import ZeusDesign

/// TB1: the conversation status strip's model, copy, icons and rendering.
@MainActor
struct ZeusStatusStripTests {
    private static let all: [ZeusStatusStripModel] = {
        let managed = ZeusStatusStripModel.buttons(hasTerminal: true, isManaged: true)
        return [.waiting(questions: 1, buttons: managed), .waiting(questions: 2), .waiting(questions: 1, skippable: false),
                .unread(1), .unread(3), .blocked(mirrored: false, buttons: managed), .blocked(mirrored: true),
                .activity("Claude is working on tests"), .notDelivered(), .quiet(until: "8:00"),
                .idle(buttons: ZeusStatusStripModel.buttons(hasTerminal: false, isManaged: false, canClear: false))]
    }()

    @Test func copyMatchesEveryRow() {
        func line(_ m: ZeusStatusStripModel) -> String {
            [m.glyph?.rawValue, m.sentence, m.actionTitle, m.skipTitle].compactMap { $0 }.joined(separator: " · ")
                .replacingOccurrences(of: "? · ", with: "? ").replacingOccurrences(of: "! · ", with: "! ")
        }
        #expect(Self.all.map(line) == [
            "? Waiting for your answer · Go to question · Skip", "? 2 questions · Go to oldest · Skip", "? Waiting for your answer · Go to question",
            "! Unread · Show", "! 3 unread · Show", "! Waiting for you in Terminal · Open", "! Waiting for your answer · Go to prompt",
            "Claude is working on tests", "Message not delivered · Show", "Quiet until 8:00", "Idle",
        ])
        #expect(ZeusStatusStripModel.idle().isQuiet && ZeusStatusStripModel.quiet(until: "8:00").isQuiet)
        #expect(!ZeusStatusStripModel.activity("x").isQuiet)
        #expect(ZeusStatusStripModel.unread(3).spokenSentence == "Alert. 3 unread")
    }

    @Test func modelIsEquatable() {
        #expect(ZeusStatusStripModel.unread(2) == .unread(2))
        #expect(ZeusStatusStripModel.unread(2) != .unread(3))
        #expect(ZeusStatusStripModel.waiting(questions: 1) != .waiting(questions: 1, skippable: false))
        var disabled = ZeusStatusStripModel.idle(buttons: ZeusStatusStripModel.buttons(hasTerminal: true, isManaged: false))
        #expect(disabled == .idle(buttons: ZeusStatusStripModel.buttons(hasTerminal: true, isManaged: false)))
        disabled.buttons[0].isEnabled = false
        #expect(disabled != .idle(buttons: ZeusStatusStripModel.buttons(hasTerminal: true, isManaged: false)))
    }

    @Test func buttonsFollowTheSession() {
        #expect(ZeusStatusStripModel.buttons(hasTerminal: true, isManaged: true).map(\.button) == [.terminal, .newConversation, .clear, .settings])
        #expect(ZeusStatusStripModel.buttons(hasTerminal: true, isManaged: false).map(\.button) == [.terminal, .clear, .settings])
        #expect(ZeusStatusStripModel.buttons(hasTerminal: false, isManaged: false).map(\.button) == [.clear, .settings])
        #expect(ZeusStatusStripModel.buttons(hasTerminal: false, isManaged: false, canClear: false).first?.isEnabled == false)
    }

    @Test func iconsAreTwelvePixelSquaresAndTitlesDraw() {
        for button in ZeusStatusStripModel.Button.allCases {
            #expect(button.rows.count == 12, "\(button)")
            #expect(button.rows.allSatisfy { $0.count == 12 && $0.allSatisfy { $0 == "#" || $0 == "." } }, "\(button)")
            #expect(ZeusFonts.pixelFontMissingGlyphs(in: button.title).isEmpty, "\(button)")
        }
        #expect(ZeusStatusStripModel.Button.terminal.title == "Open in Terminal")
        for model in Self.all {
            let text = [model.glyph?.rawValue, model.sentence, model.actionTitle, model.skipTitle, "·"].compactMap { $0 }.joined()
            #expect(ZeusFonts.pixelFontMissingGlyphs(in: text).isEmpty, "\(model.sentence)")
        }
    }

    @Test func rendersEveryState() throws {
        for model in Self.all {
            for scheme in [ColorScheme.light, .dark] {
                let view = ZeusStatusStrip(model, onJump: {}, onSkip: {}).frame(width: 360).environment(\.colorScheme, scheme)
                let image = try #require(ImageRenderer(content: view).cgImage, "\(model.sentence)")
                #expect(image.height >= Int(ZeusStatusStrip.height + ZeusTheme.pixel), "\(model.sentence)")
            }
        }
    }
}
