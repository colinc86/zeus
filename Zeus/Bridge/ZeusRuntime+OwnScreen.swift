import Foundation
import ZeusProtocol

extension ZeusRuntime {
    struct OwnScreenLease: Equatable {
        let destination: OwnSessionScreenDestination
        let responseToken: UUID
        let generation: UUID
    }
    static let ownScreenCadence: TimeInterval = 3

    /// No automatic pane, namespace or session fallback. Only the selected assistant is sampled.
    func ownScreenLease() -> OwnScreenLease? {
        guard running, !managedController.enabled, routing.deliveryMethod == .tmux, let key = assistantTarget,
              let record = activityRecords[key], record.value.phase != .working,
              let session = sessions.first(where: { $0.sessionKey == key }),
              let pane = routing.tmuxTarget, let number = UInt64(pane.dropFirst()), pane == "%\(number)",
              let socket = OwnSessionScreenReader.normalizedSocket((routing as? any TmuxTargetRouting)?.tmuxTargetSocketPath),
              socket == OwnSessionScreenReader.normalizedSocket(bridges[key]?.hello.tmuxSocketPath ?? session.tmuxSocketPath),
              let suffix = key.split(separator: "#").last else { return nil }
        let parts = suffix.split(separator: ".")
        guard parts.count == 2, let pid = Int(parts[0]), pid > 1, let start = UInt64(parts[1]), start > 0 else { return nil }
        return .init(destination: .init(sessionKey: key, sessionID: session.id, agent: session.agent, pane: pane, socket: socket, agentPID: pid, agentStart: start),
                     responseToken: record.responseToken, generation: generation)
    }
    func reconcileOwnScreenSampling() {
        let next = ownScreenLease()
        guard next != ownScreenSamplingLease else { return }
        ownScreenTask?.cancel(); ownScreenTask = nil
        if let previous = ownScreenSamplingLease { activityWorkingSeen.remove(previous.destination.sessionKey) }
        ownScreenSamplingLease = next
        guard let next else { return }
        let clock = clock
        ownScreenTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard await self?.sampleOwnScreen(next) == true else { return }
                do { try await clock.sleep(until: clock.now.addingTimeInterval(Self.ownScreenCadence)) } catch { return }
            }
        }
    }
    /// Captures never overlap. An old capture cannot affect a replacement response/selection/runtime.
    func sampleOwnScreen(_ lease: OwnScreenLease) async -> Bool {
        guard !Task.isCancelled, ownScreenLease() == lease else { return false }
        let began = clock.now
        do {
            let snapshot = try await ownScreenReader.capture(lease.destination, stillAllowed: { [weak self] in self?.ownScreenLease() == lease })
            guard !Task.isCancelled, ownScreenLease() == lease,
                  let record = activityRecords[lease.destination.sessionKey], began >= record.value.since else { return false }
            let completed: Bool
            if lease.destination.agent == .claude, let id = record.deliveryID,
               let input = TmuxInputSnapshot(metadata: Data(snapshot.inputMetadata.utf8), screen: Data(snapshot.screen.utf8)),
               let composer = input.claudeInputStart {
                // Own sessions have no pre-delivery screen baseline. Require this
                // exact input in history; neither an old footer nor a draft is proof.
                let history = ManagedPaneSnapshot(screen: snapshot.screen.components(separatedBy: "\n").prefix(composer).joined(separator: "\n"), inputMetadata: snapshot.inputMetadata)
                let turn = Self.claudeCompletedTurn(history)
                completed = turn?.hasPrefix("❯ [zeus delivery_id=\(id)]") == true || turn?.hasPrefix("❯ [zeus delivery_id=\(id) ") == true
            } else {
                completed = record.deliveryID.map { ManagedTurnCompletion.deliveryID(in: snapshot, agent: lease.destination.agent) == $0 } ?? false
            }
            noteScreenActivity(sessionKey: lease.destination.sessionKey, classification: ManagedPaneClassifier.classify(snapshot, agent: lease.destination.agent), completed: completed)
        } catch { /* Unknown/dead/replaced panes are not completion evidence. Stale fallback remains. */ }
        return !Task.isCancelled && ownScreenLease() == lease
    }
}
