import Foundation
import ZeusProtocol

/// One exact, replaceable request. Desired editor preferences are not launch evidence.
struct ManagedSettingsApplication: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case resume, newConversation, agentUpdate }
    enum Phase: Equatable, Sendable { case waiting, applying }
    let id: UUID
    let configuration: ManagedSessionConfig
    let kind: Kind
    var phase: Phase = .waiting
}

/// Optional runtime capability. Every destructive action rechecks the native pane;
/// Settings never infers safety from the last status sample alone.
@MainActor protocol ManagedSettingsApplying: AnyObject {
    var managedAppliedConfiguration: ManagedSessionConfig? { get }
    var managedSettingsApplication: ManagedSettingsApplication? { get }
    var managedSettingsApplicationError: String? { get }
    var managedCanResumeSettings: Bool { get }
    func supportsInstructionChangesOnResume(for agent: AgentKind) -> Bool
    func applyManagedSettings(_ configuration: ManagedSessionConfig)
    func switchManagedSettings(_ configuration: ManagedSessionConfig)
    func cancelManagedSettingsApplication()
}

extension ZeusRuntime: ManagedSettingsApplying {
    var managedAppliedConfiguration: ManagedSessionConfig? { managedController.managedAppliedConfiguration }
    var managedSettingsApplication: ManagedSettingsApplication? { managedController.managedSettingsApplication }
    var managedSettingsApplicationError: String? { managedController.managedSettingsApplicationError }
    var managedCanResumeSettings: Bool { managedController.managedCanResumeSettings }
    func supportsInstructionChangesOnResume(for agent: AgentKind) -> Bool { managedController.supportsInstructionChangesOnResume(for: agent) }
    func applyManagedSettings(_ configuration: ManagedSessionConfig) { managedController.applyManagedSettings(configuration) }
    func switchManagedSettings(_ configuration: ManagedSessionConfig) { managedController.switchManagedSettings(configuration) }
    func cancelManagedSettingsApplication() { managedController.cancelManagedSettingsApplication() }
}

/// Optional presentation capability for an update installed by the agent itself. No automatic restart.
@MainActor protocol ManagedAgentUpdating: AnyObject {
    var managedAgentUpdatePending: Bool { get }
    var managedAgentUpdateConversationID: String? { get }
    func restartManagedAgentForUpdate()
}

extension ZeusRuntime: ManagedAgentUpdating {
    var managedAgentUpdatePending: Bool { managedController.managedAgentUpdatePending }
    var managedAgentUpdateConversationID: String? { managedController.managedAgentUpdateConversationID }
    func restartManagedAgentForUpdate() { managedController.restartManagedAgentForUpdate() }
}
