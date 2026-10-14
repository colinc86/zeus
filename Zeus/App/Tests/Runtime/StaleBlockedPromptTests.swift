import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

/// A confirmed Terminal prompt whose dialog disappears without a positive idle/working sample must not keep a
/// "?" over Zeus forever (user report, 2026-10-14). After `staleBlockGrace` of unknown screens the block drops and
/// the prompt card is allowed to close as unconfirmed.
@MainActor
struct StaleBlockedPromptTests {
    private func isBlocked(_ f: ManagedFixture) -> Bool {
        if case .blocked = f.controller.managedStatus { return true } else { return false }
    }

    @Test func aVanishedDialogDropsTheBlockAfterTheGracePeriod() async throws {
        let f = try ManagedFixture(); defer { f.cleanup() }
        f.controller.activate(); try await f.settle()
        let blocked = try managedSnapshot("claude-blocked-permission")
        await f.host.setSnapshot(blocked)
        f.clock.advance(10, wake: false); f.controller.refresh(); try await f.settle()
        f.controller.refresh(); try await f.settle()
        #expect(isBlocked(f))

        let blank = ManagedPaneSnapshot(screen: "", inputMetadata: "0|0|120|0|1")
        await f.host.setSnapshot(blank)
        f.controller.refresh(); try await f.settle()
        #expect(isBlocked(f) && !f.controller.blockedCardStale)
        f.clock.advance(ManagedSessionController.staleBlockGrace - 1, wake: false); f.controller.refresh(); try await f.settle()
        #expect(isBlocked(f) && !f.controller.blockedCardStale)

        f.clock.advance(2, wake: false); f.controller.refresh(); try await f.settle()
        #expect(f.controller.managedStatus == .running(.unknown))
        #expect(f.controller.blockedCardStale && !f.controller.mayResolveBlockedCard)

        // The dialog coming back is a fresh block, not a stale one.
        await f.host.setSnapshot(blocked)
        f.controller.refresh(); try await f.settle(); f.controller.refresh(); try await f.settle()
        #expect(isBlocked(f) && !f.controller.blockedCardStale)
    }

    @Test func aPositiveSampleStillResolvesBeforeTheGracePeriod() async throws {
        let f = try ManagedFixture(); defer { f.cleanup() }
        f.controller.activate(); try await f.settle()
        await f.host.setSnapshot(try managedSnapshot("claude-blocked-permission"))
        f.clock.advance(10, wake: false); f.controller.refresh(); try await f.settle()
        f.controller.refresh(); try await f.settle()
        #expect(isBlocked(f))
        await f.host.setSnapshot(ManagedPaneSnapshot(screen: "", inputMetadata: "0|0|120|0|1"))
        f.controller.refresh(); try await f.settle()
        await f.host.setSnapshot(try managedSnapshot("claude-idle"))
        f.controller.refresh(); try await f.settle()
        #expect(f.controller.managedStatus == .running(.idle) && f.controller.mayResolveBlockedCard && !f.controller.blockedCardStale)
    }
}
