import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

@MainActor
struct Round5ManagedStartupTests {
    @Test(arguments: ["claude-idle", "claude-working", "claude-trust"])
    func remainsStartingUntilConfidentEvidenceAfterGrace(snapshot: String) async throws {
        let f = try ManagedFixture(); defer { f.cleanup() }
        f.controller.activate(); try await f.settle()
        #expect(f.controller.managedStatus == .starting && !f.controller.canAcceptInput)
        await f.host.setSnapshot(try managedSnapshot(snapshot))
        f.controller.refresh(); try await f.settle()
        f.clock.advance(9, wake: false); f.controller.refresh(); try await f.settle()
        #expect(f.controller.managedStatus == .starting && !f.controller.mayResolveBlockedCard)
        f.clock.advance(1, wake: false); f.controller.refresh(); try await f.settle()
        if snapshot == "claude-trust" {
            guard case .blocked(let reason) = f.controller.managedStatus else { Issue.record("Missing trust prompt"); return }
            #expect(reason.hasSuffix("?") && !reason.contains("If not,"))
        } else { #expect(f.controller.managedStatus == .running(snapshot == "claude-idle" ? .idle : .working)) }
    }
    @Test func unknownCaptureDoesNotDeclareFirstStartupComplete() async throws {
        let f = try ManagedFixture(); defer { f.cleanup() }
        f.controller.activate(); try await f.settle(); f.clock.advance(15, wake: false)
        await f.host.setSnapshot(.init(screen: "", inputMetadata: "0|0|120|0|1"))
        f.controller.refresh(); try await f.settle()
        #expect(f.controller.managedStatus == .starting && !f.controller.mayResolveBlockedCard)
    }
}
