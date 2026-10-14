import Foundation
import Testing
@testable import ZeusDesign

/// D3-10: buttons ZeusDesign draws use title case and the app's words (CONVERSATION.md, D2-3 and D2-16).
struct ZeusButtonLabelTests {
    static let minorWords: Set<String> = ["a", "an", "and", "as", "at", "for", "in", "of", "on", "or", "the", "to"]

    /// Title case: the first word and every major word start with a capital.
    static func isTitleCase(_ label: String) -> Bool {
        let words = label.split(separator: " ").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "…")) }
        return words.enumerated().allSatisfy { index, word in
            guard let first = word.first else { return true }
            return first.isUppercase || first.isNumber || (index > 0 && minorWords.contains(word))
        }
    }

    @Test func titleCaseCheckerWorks() {
        #expect(Self.isTitleCase("Show in Finder") && Self.isTitleCase("Discard…") && Self.isTitleCase("Hide for 1 Hour"))
        #expect(!Self.isTitleCase("Retry now") && !Self.isTitleCase("Discard them"))
    }

    @Test func warningPopoverLabelsAreTitleCase() {
        let labels = [ZeusWarningPopover.Labels.retry, ZeusWarningPopover.Labels.discard,
                      ZeusWarningPopover.Labels.confirmDiscard, ZeusWarningPopover.Labels.keep]
        #expect(labels == ["Retry Now", "Discard…", "Discard Them", "Keep"])
        for label in labels { #expect(Self.isTitleCase(label), "\(label)") }
    }

    @Test func attachmentRowSaysShowInFinder() {
        #expect(ZeusAttachmentRow.revealLabel == "Show in Finder")
    }

    @Test func managedActionLabelsAreTitleCase() {
        for action in ZeusManagedPresentation.Action.allCases {
            #expect(Self.isTitleCase(action.title), "\(action.title)")
            #expect(Self.isTitleCase(action.menuTitle), "\(action.menuTitle)")
        }
    }
}
