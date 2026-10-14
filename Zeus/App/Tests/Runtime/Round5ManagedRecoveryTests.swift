import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

@MainActor
struct Round5ManagedRecoveryTests {
    @Test(arguments: [AgentKind.codex, .opencode], [false, true])
    func missingContextRequiresExplicitNewConversation(agent: AgentKind, crash: Bool) async throws {
        let f = try ManagedDeliveryFixture(agent: agent); defer { f.cleanup() }
        await f.managed.finder.setID(nil)
        try await f.start()
        let nonce = f.managed.controller.record?.conversation?.nonce
        if crash {
            await f.managed.host.die()
            f.managed.controller.refresh()
        } else { f.runtime.stopManagedSession() }
        try await f.managed.settle()
        #expect(f.runtime.managedHasLaunched && f.runtime.managedNeedsNewConversation)
        #expect(f.managed.controller.recoveryRequirement == .newConversation)
        if crash { #expect({ if case .failed = f.runtime.managedStatus { true } else { false } }()) }
        f.runtime.startManagedSession(); try await f.managed.settle()
        #expect(await f.managed.host.commands.count == 1)
        #expect(f.runtime.managedNeedsNewConversation)
        #expect(f.managed.controller.record?.conversation?.nonce == nonce)
        await f.managed.finder.setID(agent == .opencode ? "ses_fresh" : UUID().uuidString)
        f.runtime.startNewManagedConversation(); try await f.managed.settle()
        #expect(await f.managed.host.commands.count == 2)
        #expect(f.managed.controller.record?.conversation?.nonce != nonce)
        #expect(!f.runtime.managedNeedsNewConversation)
        #expect(f.managed.controller.record?.conversation?.nativeID != nil)
    }
}
