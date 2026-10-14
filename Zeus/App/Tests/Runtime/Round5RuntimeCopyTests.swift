import Foundation
import Testing
import ZeusDesign
import ZeusLink
import ZeusProtocol
@testable import Zeus

@MainActor
struct Round5RuntimeCopyTests {
    @Test func runtimeErrorsUseTheDesignerCopyAndKeepDiagnosticsOutOfCaptions() {
        #expect(ConnectorError.processExit(17).localizedDescription == ZeusRuntimeCopy.Delivery.terminalFailed)
        #expect(ConnectorError.httpStatus(401).localizedDescription == ZeusRuntimeCopy.Delivery.openCodePasswordRejected)
        #expect(ConnectorError.httpStatus(404).localizedDescription == ZeusRuntimeCopy.Delivery.openCodeConversationNotFound)
        #expect(ManagedSessionError.terminalCommand("tmux raw diagnostic").localizedDescription == ZeusRuntimeCopy.Managed.terminalFailed)
        #expect(ManagedSessionError.invalidState.localizedDescription == ZeusRuntimeCopy.Managed.invalidState)
        #expect(ZeusRuntime.deliveryErrorDescription(BridgeLinkError.timeout) == ZeusRuntimeCopy.Delivery.linkTimedOut)
    }
}
