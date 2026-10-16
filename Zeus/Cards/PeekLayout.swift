import AppKit
import SwiftUI
import ZeusDesign
import ZeusProtocol

/// Measures the same SwiftUI content that the panel displays, before its first frame.
/// No line-height estimates or measurements of the partially revealed text are used.
struct PeekLayout: Equatable {
    var width: CGFloat = ZeusPeekTiming.maxWidth
    var bodyLines = 6
    var showsMore = false
    var contentSize = CGSize.zero

    var textWidth: CGFloat { width - ZeusTheme.pixel - 2 * (ZeusTheme.Spacing.s + ZeusTheme.borderWidth) }

    @MainActor static func measure(card: Card, font: ZeusFontChoice, scale: ZeusFontScale = .default, moreCount: Int, error: String?,
                                   answeredOptionID: String?, available: CGSize, ratings: MessageRatingsModel? = nil) -> PeekLayout {
        // Leave room for either tail orientation and the dialog's drawn shadow.
        var layout = PeekLayout(width: min(ZeusPeekTiming.maxWidth, max(1, available.width - ZeusDialogTail.height)))
        let full = textHeight(card.body, font: font, scale: scale, width: layout.textWidth, lines: nil)
        for lines in stride(from: 6, through: 1, by: -1) {
            layout.bodyLines = lines
            layout.showsMore = full > textHeight(card.body, font: font, scale: scale, width: layout.textWidth, lines: lines) + 0.5
            let content = PeekContent(card: card, layout: layout, moreCount: moreCount, error: error,
                                      answeredOptionID: answeredOptionID, tail: nil, reveal: .full, ratings: ratings)
                .environment(\.zeusFontChoice, font).environment(\.zeusFontScale, scale).environment(\.zeusAnimationsActive, false)
            let size = NSHostingView(rootView: content).fittingSize
            layout.contentSize = CGSize(width: ceil(size.width), height: ceil(size.height))
            if layout.contentSize.height + ZeusDialogTail.height <= available.height { break }
        }
        return layout
    }

    @MainActor private static func textHeight(_ body: String, font: ZeusFontChoice, scale: ZeusFontScale, width: CGFloat, lines: Int?) -> CGFloat {
        let text = Text(ZeusMarkdown.attributed(body, choice: font, palette: .dark))
            .zeusFont(.body).lineLimit(lines).fixedSize(horizontal: false, vertical: true)
            .frame(width: width, alignment: .leading).environment(\.zeusFontChoice, font).environment(\.zeusFontScale, scale)
        return NSHostingView(rootView: text).fittingSize.height
    }
}
