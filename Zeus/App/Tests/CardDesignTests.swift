import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

struct CardDesignTests {
    @Test func dialogTailFollowsAnchorAboveAndBelow() {
        let screen = CGRect(x: -1440, y: 0, width: 1440, height: 900)
        let low = CGRect(x: -750, y: 100, width: 144, height: 168)
        let anchor = CGPoint(x: -678, y: 109)
        let above = DialogPlacement.place(art: low, anchor: anchor, size: CGSize(width: 364, height: 520), screen: screen)
        #expect(above.tail.edge == .bottom)
        #expect(above.frame.minY == low.maxY + 4)
        #expect(above.frame.midX == anchor.x)
        #expect(abs(above.frame.minX + above.tail.offset - anchor.x) <= 1)
        let high = low.offsetBy(dx: 0, dy: 540)
        let highAnchor = CGPoint(x: anchor.x, y: anchor.y + 540)
        let below = DialogPlacement.place(art: high, anchor: highAnchor, size: CGSize(width: 364, height: 520), screen: screen)
        #expect(below.tail.edge == .top)
        #expect(abs(below.frame.maxY - (highAnchor.y - 4)) <= 1)
    }

    @Test func dialogClampsAndSnapsTailAtScreenEdge() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let avatar = CGRect(x: 10, y: 100, width: 144, height: 168)
        let placement = DialogPlacement.place(art: avatar, anchor: CGPoint(x: 20, y: 109), size: CGSize(width: 364, height: 520), screen: screen)
        #expect(screen.contains(placement.frame))
        #expect(placement.frame.minX == 8)
        #expect(placement.tail.offset == 16)
        #expect(placement.frame.minY.truncatingRemainder(dividingBy: 2) == 0)
    }
}
