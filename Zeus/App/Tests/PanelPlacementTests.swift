import Foundation
import Testing
@testable import Zeus

struct PanelPlacementTests {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let size = CGSize(width: 380, height: 420)

    @Test func cardPrefersAbove() {
        let avatar = CGRect(x: 650, y: 100, width: 112, height: 128)
        let card = PanelPlacement.card(near: avatar, size: size, screen: screen)
        #expect(card.minY == avatar.maxY + 12)
        #expect(card.midX == avatar.midX)
    }

    @Test func cardFallsBelowAtTop() {
        let avatar = CGRect(x: 650, y: 740, width: 112, height: 128)
        let card = PanelPlacement.card(near: avatar, size: size, screen: screen)
        #expect(card.maxY == avatar.minY - 12)
    }

    @Test func cardClampsAtDisplayEdges() {
        let avatar = CGRect(x: 1318, y: 100, width: 112, height: 128)
        let card = PanelPlacement.card(near: avatar, size: size, screen: screen)
        #expect(card.maxX == screen.maxX - 10)
        #expect(screen.contains(card))
    }

    @Test func clampHandlesNegativeDisplayCoordinates() {
        let left = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
        let panel = CGRect(x: -2100, y: -400, width: 112, height: 128)
        let clamped = PanelPlacement.clamp(panel, to: left)
        #expect(clamped.origin == CGPoint(x: -1910, y: -190))
        #expect(left.contains(clamped))
    }

    @Test func usesLargestOverlapForStraddlingPanel() {
        let right = CGRect(x: 1440, y: 100, width: 1920, height: 1080)
        let panel = CGRect(x: 1400, y: 200, width: 112, height: 128)
        #expect(PanelPlacement.screen(for: panel, in: [screen, right]) == right)
    }

    @Test func disconnectedDisplayChoosesNearestRemainingScreen() {
        let panel = CGRect(x: -1600, y: 100, width: 112, height: 128)
        let right = CGRect(x: 1440, y: 100, width: 1920, height: 1080)
        #expect(PanelPlacement.screen(for: panel, in: [right, screen]) == screen)
        #expect(screen.contains(PanelPlacement.clamp(panel, to: screen)))
    }

    @Test func smallDisplayStillContainsCard() {
        let small = CGRect(x: 300, y: 200, width: 320, height: 360)
        let avatar = CGRect(x: 450, y: 240, width: 112, height: 128)
        let card = PanelPlacement.card(near: avatar, size: size, screen: small)
        #expect(small.contains(card))
        #expect(card.size == CGSize(width: 300, height: 340))
    }

    @Test func noDisplaysHasNoPlacement() {
        #expect(PanelPlacement.screen(for: .zero, in: []) == nil)
    }
}
