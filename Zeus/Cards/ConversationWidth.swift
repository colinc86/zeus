import Foundation
import ZeusDesign

/// Whole-point widths, capped to half the usable screen. Very small screens take
/// precedence over the usual minimum so the panel still fits after a display change.
enum ConversationWidth {
    enum Edge { case left, right }
    static let minimum = ZeusTheme.Conversation.panelWidth
    static func clamp(_ requested: CGFloat, screenWidth: CGFloat) -> CGFloat {
        let maximum = max(1, floor(screenWidth / 2))
        let lower = min(minimum, maximum)
        return min(maximum, max(lower, requested.isFinite ? requested.rounded() : minimum))
    }
    static func edge(avatarX: CGFloat, panel: CGRect, screen: CGRect) -> Edge {
        if abs(avatarX - panel.midX) < 1 { return avatarX >= screen.midX ? .left : .right }
        return avatarX >= panel.midX ? .left : .right
    }
    static func dragged(startWidth: CGFloat, delta: CGFloat, edge: Edge) -> CGFloat {
        (startWidth + (edge == .left ? -delta : delta)).rounded()
    }
    static func origin(fixedX: CGFloat, width: CGFloat, edge: Edge, screen: CGRect) -> CGFloat {
        let x = edge == .left ? fixedX - width : fixedX
        return min(max(x.rounded(), screen.minX + 8), screen.maxX - 8 - width)
    }
    static func bubble(panelWidth: CGFloat, user: Bool) -> CGFloat {
        let usual = user ? ZeusTheme.Conversation.userBubbleMaxWidth : ZeusTheme.Conversation.agentBubbleMaxWidth
        return max(1, usual + panelWidth - minimum)
    }
}
