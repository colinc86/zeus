import SwiftUI
import ZeusDesign

struct DeliveryWarningView: View {
    let messaging: any AgentMessaging
    let settings: AppSettings
    @Bindable var managed: ManagedAssistantModel
    let close: () -> Void
    let openSettings: () -> Void
    @State private var retried = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    /// This root's own colors come from the theme directly: the environment it sets applies to its children.
    private var palette: ZeusPalette { settings.currentTheme.palette(for: colorScheme, contrast: colorSchemeContrast) }

    var recovery: DeliveryWarningPresentation {
        let hub = messaging as? AgentMessagingHub
        let preview = hub?.previewEnabled == true
        let capability = (messaging as? any ManagedPresentationProviding) ?? (hub?.runtime as? any ManagedPresentationProviding)
        return .make(managedStatus: !preview && managed.enabled ? managed.status : nil,
                     needsNewConversation: !preview && managed.requiresFreshConversation,
                     canStart: managed.canStart, canRetry: preview || capability?.canRetryPendingDeliveries == true)
    }
    var primaryAction: ZeusWarningPopover.PrimaryAction? {
        guard let action = recovery.action, let title = recovery.primaryTitle else { return nil }
        return .init(title) { perform(action) }
    }
    func perform(_ action: DeliveryWarningPresentation.Action) {
        // Recheck availability: state may have changed while the popover was open.
        guard recovery.action == action else { return }
        switch action {
        case .retry: retried = true; messaging.retryPendingDeliveries()
        case .startAssistant:
            managed.perform(.start)
            if managed.confirmation != nil { close(); openSettings() }
        case .newConversation:
            managed.confirmation = .newConversation
            close(); openSettings()
        case .openSettings: close(); openSettings()
        }
    }
    func discard() { messaging.discardPendingDeliveries(); close() }

    // T1: the selected theme reaches every view below through \.zeusTheme (and so \.zeusPalette).
    var body: some View { rootBody.environment(\.zeusTheme, settings.currentTheme) }

    @ViewBuilder private var rootBody: some View {
        Group {
            if let issue = messaging.deliveryIssue {
                VStack(spacing: 8) {
                    ZeusWarningPopover(title: issue.title, message: issue.detail,
                                       footnote: nil, // The detail says whether Zeus sends them by itself (D2-6).
                                       primary: primaryAction,
                                       onDiscard: discard)
                    if retried { Text(DeliveryWarningPresentation.retryNotice).zeusFont(.caption).foregroundStyle(palette.secondaryText).frame(width: 272) }
                }
            }
        }
        .environment(\.zeusFontChoice, settings.fontChoice)
        .onChange(of: messaging.deliveryIssue) { if messaging.deliveryIssue == nil { close() } }
    }
}
