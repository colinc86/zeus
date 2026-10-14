import SwiftUI
import Testing
@testable import ZeusDesign

/// A4D-5 (R5a request): the delivery warning's primary button is whatever fixes the problem, or none at all.
@MainActor
struct ZeusWarningPopoverTests {
    @Test func legacyInitStillOffersRetryNow() {
        var retried = false
        let popover = ZeusWarningPopover(message: "1 message is waiting.", onRetry: { retried = true }, onDiscard: {})
        #expect(popover.primary?.title == "Retry Now")
        popover.primary?.action()
        #expect(retried)
    }

    @Test func primaryCanBeAStartActionOrNothing() {
        var started = false
        let start = ZeusWarningPopover(message: "Claude Code is stopped. Start it to send 1 message.",
                                       primary: .init(ZeusWarningPopover.Labels.startAssistant) { started = true }, onDiscard: {})
        start.primary?.action()
        #expect(start.primary?.title == "Start Assistant" && started)
        let inert = ZeusWarningPopover(message: "Your assistant isn't connected.", primary: nil, onDiscard: {})
        #expect(inert.primary == nil)
    }

    @Test func newLabelsAreTitleCaseAndDrawable() {
        for label in [ZeusWarningPopover.Labels.startAssistant, ZeusWarningPopover.Labels.startNewConversation] {
            #expect(ZeusButtonLabelTests.isTitleCase(label), "\(label)")
            #expect(ZeusFonts.pixelFontMissingGlyphs(in: label).isEmpty)
        }
        #expect(ZeusWarningPopover.Labels.startAssistant == ZeusManagedPresentation.Action.start.menuTitle)
    }

    @Test func rendersWithAndWithoutAPrimaryButton() {
        for primary in [ZeusWarningPopover.PrimaryAction?.none, .retry({})] {
            let view = ZeusWarningPopover(message: "1 message is waiting.", primary: primary, onDiscard: {})
            #expect(ImageRenderer(content: view).cgImage != nil)
        }
    }
}
