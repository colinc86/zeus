import SwiftUI
import ZeusProtocol
import ZeusDesign

/// One explicit native destination per Zeus connection. Missing/deleted choices stay visible.
struct OpenCodeSessionPicker: View {
    @Bindable var settings: AppSettings
    let messaging: any AgentMessaging
    @State private var discovery = OpenCodeSessionDiscovery()
    private var target: ConnectedSession? {
        if let selected = settings.assistantSessionKey {
            return messaging.sessions.first { $0.sessionKey == selected && $0.agent == .opencode }
        }
        guard settings.preferredAgent == .opencode else { return nil }
        return settings.assistantCandidates(messaging.sessions).first { $0.agent == .opencode }
    }
    private var scope: String { (settings.openCodeBaseURL?.absoluteString ?? "") + "|" + (target?.sessionKey ?? "") }
    private var selection: String? { target.flatMap { settings.savedOpenCodeSessionID(for: $0.sessionKey) } }

    var body: some View {
        let listed = discovery.sessions
        let endpoint = discovery.listedBaseURL
        return VStack(alignment: .leading, spacing: 6) {
            Text("OpenCode can run several conversations in one folder. Choose the one that gets your messages, or let it check in.").settingsCaption()
            if let target {
                let notice = settings.openCodeSelectionNotice(for: target.sessionKey)
                Text("Folder: " + settings.sessionLabels.label(target.sessionKey)).settingsCaption()
                HStack {
                    ZeusMenuPicker("Conversation", choices: Self.choices(sessions: listed, selected: selection),
                        selection: Binding(get: { notice == nil ? selection : nil }, set: { id in
                            if Self.select(id, for: target.sessionKey, sessions: listed, endpoint: endpoint, settings: settings) { messaging.retryPendingDeliveries() }
                        }), placeholder: ZeusRuntimeCopy.OpenCode.choosePlaceholder)
                        .disabled(discovery.isLoading)
                    Button(discovery.isLoading ? "Refreshing…" : "Refresh") { Task { await refresh() } }
                        .accessibilityLabel("Refresh OpenCode Conversations")
                        .disabled(discovery.isLoading || settings.openCodeBaseURL == nil)
                }
                if let notice {
                    Text(notice).settingsCaption().textSelection(.enabled)
                } else if let selected = discovery.sessions.first(where: { $0.id == selection }) {
                    Text(selected.selectionDetail).settingsCaption().textSelection(.enabled)
                } else if selection != nil && !discovery.isLoading {
                    Text("Your saved conversation isn't listed right now. Zeus keeps it; refresh, or choose another.").settingsCaption()
                } else if discovery.sessions.isEmpty && discovery.error == nil && !discovery.isLoading {
                    Text("No OpenCode conversations in \(target.cwd) yet. Start one there, then refresh.").settingsCaption()
                }
            } else {
                Text(ZeusRuntimeCopy.OpenCode.notConnected).settingsCaption()
            }
            if let error = discovery.error { Text(error).settingsCaption() }
            Button("Let It Check In Instead") { settings.deliveryMethod = .polling }.accessibilityLabel("Let It Check In Instead")
        }
        .task(id: scope) { await refresh() }
    }
    static func choices(sessions: [OpenCodeNativeSession], selected: String?) -> [ZeusChoice<String>] {
        let labels = OpenCodeNativeSession.labels(for: sessions)
        var choices = sessions.map { ZeusChoice(id: $0.id, title: labels[$0.id] ?? $0.label, detail: $0.id) }
        if let selected, !sessions.contains(where: { $0.id == selected }) {
            choices.append(ZeusChoice(id: selected, title: OpenCodeNativeSession.selectedLabel(selected, sessions: sessions), isEnabled: false))
        }
        return choices
    }
    @discardableResult static func select(_ id: String?, for key: String, sessions: [OpenCodeNativeSession], endpoint: URL?, settings: AppSettings) -> Bool {
        guard let id else { return false } // No nil menu item: "Choose…" is a prompt, not Discard.
        let listedEndpoint = endpoint.flatMap(OpenCodeDestination.canonicalEndpoint)
        let currentEndpoint = settings.openCodeBaseURL.flatMap(OpenCodeDestination.canonicalEndpoint)
        guard listedEndpoint != nil && listedEndpoint == currentEndpoint && sessions.contains(where: { $0.id == id }) else { return false }
        return settings.setOpenCodeSessionID(id, for: key)
    }
    private func refresh() async {
        await discovery.refresh(baseURL: settings.openCodeBaseURL, directory: target?.cwd, password: settings.openCodeServerPassword)
    }
}
