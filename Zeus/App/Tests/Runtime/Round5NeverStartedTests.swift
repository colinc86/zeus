import Foundation
import Testing
import ZeusDesign
import ZeusLink
import ZeusProtocol
@testable import Zeus

@MainActor
struct Round5NeverStartedTests {
    @Test func neverLaunchedDoesNotReportAnExitAndRemainsReadyToStart() async throws {
        let f = try ManagedFixture(); defer { f.cleanup() }
        f.config.value?.startWhenZeusOpens = false
        f.controller.activate(); try await f.settle()
        #expect(f.controller.managedStatus == .off && !f.controller.hasLaunched)
        #expect(await f.host.commands.isEmpty)
        f.controller.startManagedSession(); try await f.settle()
        #expect(f.controller.hasLaunched)
        f.controller.stopManagedSession(); try await f.settle()
        #expect(f.controller.managedStatus == .stopped && f.controller.hasLaunched)
    }

}
