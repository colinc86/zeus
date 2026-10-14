import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

@MainActor private final class LegacyMessaging: AgentMessaging {
    var sessions: [ConnectedSession] = []
    var messages: [String] = []
    func sendUserMessage(_ text: String) async -> MessageSendResult { messages.append(text); return .delivered }
}

@MainActor private final class LegacyRouting: AgentRoutingSettings {
    var assistantSessionKey: String? { nil }
    var deliveryMethod: DeliveryMethod { .polling }
    var tmuxTarget: String? { nil }
    var openCodeBaseURL: URL? { nil }
}

@MainActor struct SeamCompatibilityTests {
    @Test func newMethodsAndMetadataPreserveOldImplementations() async {
        let legacy: any AgentMessaging = LegacyMessaging()
        #expect(await legacy.sendUserMessage("Old fake", deliveryID: "d_same") == .delivered)
        #expect(legacy.userMessageDeliveries.isEmpty)
        let routing: any AgentRoutingSettings = LegacyRouting()
        #expect(routing.openCodeSessionID(for: "opencode:/folder#1.2") == nil)
        let old = ConnectedSession(id: UUID(), sessionKey: "claude:/folder#1.2", agent: .claude, cwd: "/folder",
                                   clientName: nil, supportsChannel: true, tmuxPane: "%0", connectedAt: Date())
        #expect(old.tmuxSocketPath == nil)
    }

    @Test func promotedRoutingMethodUsesSettingsWitnessWithoutTheOptionalAdapter() {
        let settings = FakeRouting(); settings.openCodeSessionIDs["opencode:/folder#1.2"] = "ses_exact"
        let routing: any AgentRoutingSettings = settings
        let context = DeliveryRoutingContext(settings: routing, assistantSessionKey: "opencode:/folder#1.2")
        #expect(context.openCodeSessionID(for: "opencode:/folder#1.2") == "ses_exact")
    }
}
