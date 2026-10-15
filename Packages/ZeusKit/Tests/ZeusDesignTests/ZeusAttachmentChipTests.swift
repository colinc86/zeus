import CoreGraphics
import SwiftUI
import Testing
import ZeusProtocol
@testable import ZeusDesign

// LM2-R: draft attachment chips wrap instead of scrolling sideways, and say what × removes.
struct ZeusAttachmentChipTests {
    @Test func chipsWrapOntoNewRowsAndAnOversizedChipGetsItsOwnRow() {
        #expect(ZeusChipFlow.rows(widths: [100, 100, 100], maxWidth: 320, spacing: 6) == [[0, 1, 2]])
        #expect(ZeusChipFlow.rows(widths: [100, 100, 100], maxWidth: 300, spacing: 6) == [[0, 1], [2]])
        #expect(ZeusChipFlow.rows(widths: [400, 50, 50], maxWidth: 300, spacing: 6) == [[0], [1, 2]])
        #expect(ZeusChipFlow.rows(widths: [], maxWidth: 300, spacing: 6).isEmpty)
    }

    @Test func removeButtonNamesTheItem() {
        let item = Attachment(id: "a", kind: .folder, label: "Website", target: "/tmp/Website")
        #expect(ZeusAttachmentChip.removeLabel(item) == "Remove Website")
    }

    @Test func pictureChipsShowASmallThumbnail() {
        #expect(ZeusAttachmentChip.thumbnailSize == CGSize(width: 32, height: 20))
        let chip = ZeusAttachmentChip(Attachment(id: "p", kind: .file, label: "Picture · Xcode", target: "/tmp/p.heic"),
                                      thumbnail: Image(systemName: "photo"), onRemove: {})
        #expect(chip.thumbnail != nil && chip.actionTitle == nil)
    }

    @Test func fixedAppearanceThemesPickTheirOwnScheme() {
        let themes = ZeusThemeLibrary.load(userDirectory: nil).themes
        let fixed = Dictionary(uniqueKeysWithValues: themes.map { ($0.id, $0.fixedAppearance) })
        #expect(fixed["parchment"] == .light && fixed["midnight"] == .dark && fixed["classic"] == ColorScheme?.none)
    }
}
