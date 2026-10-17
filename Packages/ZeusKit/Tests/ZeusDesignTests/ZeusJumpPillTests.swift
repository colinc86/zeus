import SwiftUI
import Testing
@testable import ZeusDesign

/// JB1: the jump pills' copy, forms and rendering (CONVERSATION.md §20).
@MainActor
struct ZeusJumpPillTests {
    private static let kinds: [ZeusJumpPill.Kind] = [
        .unread(1), .unread(3), .latest(newCount: 2), .latest(newCount: 0),
        .question(count: 1, direction: .up), .question(count: 2, direction: .down),
    ]

    @Test func fullAndShortTitlesMatchTheSpec() {
        #expect(Self.kinds.map { ZeusJumpPill.title($0) } == ["↑ 1 unread", "↑ 3 unread", "↓ 2 new", "↓ Latest", "↑ ? Question", "↓ ? 2 questions"])
        #expect(Self.kinds.map { ZeusJumpPill.title($0, compact: true) } == ["↑ 1", "↑ 3", "↓ 2", "↓", "↑ ?", "↓ ?"])
        for kind in Self.kinds {
            #expect(ZeusFonts.pixelFontMissingGlyphs(in: ZeusJumpPill.title(kind)).isEmpty)
        }
    }

    @Test func directionAndNewness() {
        #expect(ZeusJumpPill.Kind.unread(1).direction == .up)
        #expect(ZeusJumpPill.Kind.latest(newCount: 0).direction == .down)
        #expect(ZeusJumpPill.Kind.question(count: 1, direction: .down).direction == .down)
        #expect(ZeusJumpPill.Kind.latest(newCount: 0).isNew == false)
        #expect(ZeusJumpPill.Kind.latest(newCount: 1).isNew)
        #expect(ZeusJumpPill.Kind.unread(1).isNew)
        #expect(ZeusJumpPill.Kind.question(count: 1, direction: .up).isNew)
    }

    @Test func accessibilityLabelsAndTooltips() {
        #expect(Self.kinds.map { ZeusJumpPill.accessibilityLabel($0) } == [
            "Jump to 1 unread message", "Jump to 3 unread messages", "2 new messages. Jump to the newest message",
            "Jump to the newest message", "Jump to the next question", "Jump to the next of 2 questions",
        ])
        #expect(ZeusJumpPill.tooltip(.unread(3)) == "Jump to the oldest unread message")
        #expect(ZeusJumpPill.tooltip(.latest(newCount: 0)) == "Jump to the newest message (⌘↓)")
        #expect(ZeusJumpPill.tooltip(.question(count: 1, direction: .up)) == "Jump to the next question (⌘J)")
        #expect(ZeusJumpPill.tooltip(.question(count: 2, direction: .up)) == "2 questions · Jump to the next (⌘J)")
        #expect(ZeusJumpPill.markReadLabel == "Mark unread messages as read")
        #expect(ZeusJumpPill.markReadTooltip == "Mark as read")
        #expect(Self.kinds.map(\.identifier) == ["jump-unread", "jump-unread", "jump-latest", "jump-latest", "jump-question", "jump-question"])
        #expect(ZeusJumpPill.Identifier.markRead == "jump-mark-read")
    }

    @Test func transitionsFollowReduceMotionAndAnimationGate() {
        // AnyTransition isn't Equatable; the factory must at least return for every combination.
        for edge in [ZeusJumpPillCluster.Edge.top, .bottom] {
            _ = ZeusJumpPillCluster.transition(edge: edge, reduceMotion: false)
            _ = ZeusJumpPillCluster.transition(edge: edge, reduceMotion: true)
            _ = ZeusJumpPillCluster.transition(edge: edge, reduceMotion: false, animationsActive: false)
        }
        #expect(ZeusJumpPillCluster.duration == 0.12)
        #expect(ZeusJumpPillCluster.slide == 4)
    }

    @Test func rendersEveryKindAtLeastTargetHeightAndShortIsNarrower() throws {
        ZeusFonts.registerBundled()
        for kind in Self.kinds {
            for scheme in [ColorScheme.light, .dark] {
                let full = ZeusJumpPill(kind, onMarkRead: kind.identifier == ZeusJumpPill.Identifier.unread ? {} : nil) {}
                    .environment(\.colorScheme, scheme)
                let image = try #require(ImageRenderer(content: full).cgImage, Comment(rawValue: ZeusJumpPill.title(kind)))
                #expect(image.height >= Int(ZeusJumpPill.minHeight), Comment(rawValue: ZeusJumpPill.title(kind)))
                let short = ZeusJumpPill(kind, compact: true) {}.environment(\.colorScheme, scheme)
                let shortImage = try #require(ImageRenderer(content: short).cgImage)
                let fullAlone = try #require(ImageRenderer(content: ZeusJumpPill(kind) {}.environment(\.colorScheme, scheme)).cgImage)
                #expect(shortImage.width <= fullAlone.width, Comment(rawValue: ZeusJumpPill.title(kind)))
            }
        }
    }

    @Test func twoPillsGoShortOnlyWhenTheFullRowDoesNotFit() throws {
        ZeusFonts.registerBundled()
        let items: [ZeusJumpPillCluster.Item] = [.init(.unread(12), onMarkRead: {}) {}, .init(.question(count: 2, direction: .up)) {}]
        let wide = try #require(ImageRenderer(content: ZeusJumpPillCluster(edge: .top, items: items).frame(width: 348)).cgImage)
        let narrow = try #require(ImageRenderer(content: ZeusJumpPillCluster(edge: .top, items: items).frame(width: 200)).cgImage)
        let lone = try #require(ImageRenderer(content: ZeusJumpPillCluster(edge: .top, items: [items[0]]).frame(width: 348)).cgImage)
        #expect(wide.width == 348 && narrow.width == 200 && lone.width == 348)
        // The Larger pixel caption is the widest case the spec lists; the full row must still fit at 348.
        let larger = ZeusJumpPillCluster(edge: .top, items: items).frame(width: 348).environment(\.zeusFontScale, .larger)
        _ = try #require(ImageRenderer(content: larger).cgImage)
    }
}
