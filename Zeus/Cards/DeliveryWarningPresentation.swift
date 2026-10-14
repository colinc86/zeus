import Foundation
import ZeusDesign

/// The recovery action must be something the runtime can actually do now.
struct DeliveryWarningPresentation: Equatable {
    enum Action: Equatable { case retry, startAssistant, newConversation, openSettings }
    let action: Action?

    static func make(managedStatus: ManagedSessionStatus?, needsNewConversation: Bool, canStart: Bool, canRetry: Bool) -> Self {
        if needsNewConversation { return .init(action: canStart ? .newConversation : .openSettings) }
        switch managedStatus {
        case .off?, .stopped?, .failed?: return .init(action: canStart ? .startAssistant : .openSettings)
        default: return .init(action: canRetry ? .retry : nil)
        }
    }

    var primaryTitle: String? {
        switch action {
        case .retry: ZeusWarningPopover.Labels.retry
        case .startAssistant: ZeusWarningPopover.Labels.startAssistant
        case .newConversation: ZeusWarningPopover.Labels.startNewConversation
        case .openSettings: "Open Settings"
        case nil: nil
        }
    }
    static let retryNotice = "Retry requested."
}
