import Foundation

/// Document coordinates measured down from the thread's top, independent of scroll direction.
struct ConversationViewport: Equatable {
    var offset: CGFloat = 0
    var contentHeight: CGFloat = 0
    var height: CGFloat = 0
}

/// CONTRACT §10.8: follow the end until the newest message's top reaches the viewport top.
enum ConversationAutoScroll {
    static let bottomTolerance: CGFloat = 24
    static let topTolerance: CGFloat = 1

    static func targetOffset(viewport: ConversationViewport, newestMessageTop: CGFloat?, pinned: Bool) -> CGFloat {
        let maximum = max(0, viewport.contentHeight - viewport.height)
        guard pinned else { return min(maximum, max(0, viewport.offset)) }
        return min(maximum, max(0, newestMessageTop ?? maximum))
    }

    static func isPinned(viewport: ConversationViewport, newestMessageTop: CGFloat?) -> Bool {
        let maximum = max(0, viewport.contentHeight - viewport.height)
        if maximum == 0 { return true }
        if maximum - viewport.offset <= bottomTolerance { return true }
        guard let top = newestMessageTop, top < maximum else { return false }
        return abs(viewport.offset - max(0, top)) <= topTolerance
    }
}

/// Entry visibility uses a point intersection, so even a very tall row qualifies.
/// Navigation includes answer/user rows; reading consumers filter to agent-card identities.
enum ConversationViewportVisibility {
    static func visibleIDs(frames: [String: CGRect], viewport: ConversationViewport) -> Set<String> {
        guard viewport.height >= 1 else { return [] }
        return Set(frames.compactMap { id, frame in
            guard id.hasPrefix("card:") || id.hasPrefix("answer:"), frame.width > 0,
                  min(frame.maxY, viewport.offset + viewport.height) - max(frame.minY, viewport.offset) >= 1 else { return nil }
            return id
        })
    }
}

/// Reading eligibility is measured in visible points, independent of total bubble height.
enum ConversationSeenVisibility {
    static func visibleIDs(frames: [String: CGRect], viewport: ConversationViewport) -> Set<String> {
        ConversationViewportVisibility.visibleIDs(frames: frames, viewport: viewport).filter { $0.hasPrefix("card:") }
    }
}
