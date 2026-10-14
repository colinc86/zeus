import Foundation
import Testing
import ZeusProtocol
import ZeusSprites
@testable import Zeus

#if DEBUG
@MainActor
struct FrameCounterTests {
    @Test func countsPixelChangesRatherThanNewImageIdentity() throws {
        let zeus = try #require(CharacterLibrary.load(userDirectory: nil).character(id: "zeus"))
        var counts = DebugSpriteFrameCounter.Counts()
        let first = SpriteRenderer.render(zeus, state: .idle, time: 0)
        counts.record(first)
        counts.record(first)
        counts.record(SpriteRenderer.render(zeus, state: .idle, time: 0))
        #expect(counts.assignments == 3 && counts.pixelChanges == 1)
        counts.record(SpriteRenderer.render(zeus, state: .working, time: 0.7))
        #expect(counts.assignments == 4 && counts.pixelChanges == 2)
    }
}
#endif
