import Foundation
import ZeusDesign

/// The reading mode changes allocation, never the saved conversation width.
enum DocumentPanelGeometry {
    static func width(chat: CGFloat, expanded: Bool, screen: CGFloat) -> CGFloat {
        ConversationWidth.clamp(chat * (expanded ? 2 : 1), screenWidth: screen)
    }
    static func contentHeight(composer: CGFloat, strip: CGFloat, screen: CGFloat, expanded: Bool, tail: CGFloat) -> CGFloat {
        if expanded { return max(0, screen - 16 - composer - strip - 54 - tail) }
        return ConversationLayout.threadHeight(content: .greatestFiniteMagnitude, composer: composer, screen: screen, strip: strip)
    }
}
