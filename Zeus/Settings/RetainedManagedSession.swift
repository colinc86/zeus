import Foundation

/// Read-only presentation of an agent left alive after switching to Connect your own.
struct RetainedManagedSession: Equatable {
    let attachCommand: String
}

/// Managed status becomes Off on detach; this capability keeps the surviving
/// process visible without restarting its monitor or changing its routing.
@MainActor protocol RetainedManagedSessionPresenting: AnyObject {
    var retainedManagedSession: RetainedManagedSession? { get }
}

extension ZeusRuntime: RetainedManagedSessionPresenting {
    var retainedManagedSession: RetainedManagedSession? {
        // Disabled mode doesn't adopt/load the lease on launch. Reading the saved
        // lease preserves the notice after reopening Zeus without adopting the agent.
        let record = managedController.record ?? (try? managedController.store.load())
        guard let pane = record?.pane, !pane.dead,
              pane.pid > 0, pane.startTime > 0,
              !AgentSessionLiveness.isDead("managed#\(pane.pid).\(pane.startTime)") else { return nil }
        return .init(attachCommand: ManagedTerminalPresentation.attach(session: pane.name, socket: pane.socket))
    }
}
