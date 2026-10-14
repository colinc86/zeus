import Testing
@testable import Zeus

struct DeliveryWarningPresentationTests {
    @Test func disconnectedInputDoesNotOfferRetryAndDiscardRemainsIndependent() {
        let inactive = DeliveryWarningPresentation.make(managedStatus: nil, needsNewConversation: false, canStart: false, canRetry: false)
        #expect(inactive.action == nil && inactive.primaryTitle == nil)
        let exhausted = DeliveryWarningPresentation.make(managedStatus: nil, needsNewConversation: false, canStart: false, canRetry: true)
        #expect(exhausted.action == .retry && exhausted.primaryTitle == "Retry Now")
        #expect(DeliveryWarningPresentation.retryNotice == "Retry requested.")
    }
    @Test func managedInactiveStatesOfferStartOrSetupInsteadOfAnInertRetry() {
        for state in [ManagedSessionStatus.off, .stopped, .failed(reason: "Fixture")] {
            let ready = DeliveryWarningPresentation.make(managedStatus: state, needsNewConversation: false, canStart: true, canRetry: true)
            #expect(ready.action == .startAssistant && ready.primaryTitle == "Start Assistant")
            let setup = DeliveryWarningPresentation.make(managedStatus: state, needsNewConversation: false, canStart: false, canRetry: false)
            #expect(setup.action == .openSettings && setup.primaryTitle == "Open Settings")
        }
    }
    @Test func cannotResumeOffersNewConversationAndAnUnreadySetupCannotStartIt() {
        let fresh = DeliveryWarningPresentation.make(managedStatus: .failed(reason: "Fixture"), needsNewConversation: true, canStart: true, canRetry: true)
        #expect(fresh.action == .newConversation && fresh.primaryTitle == "Start New Conversation")
        let setup = DeliveryWarningPresentation.make(managedStatus: .failed(reason: "Fixture"), needsNewConversation: true, canStart: false, canRetry: true)
        #expect(setup.action == .openSettings)
    }
    @Test func blockedAndWorkingInputCannotRetryUntilRuntimeSaysItCan() {
        for state in [ManagedSessionStatus.blocked(reason: "Permission"), .running(.working), .starting, .restarting(at: .distantFuture)] {
            #expect(DeliveryWarningPresentation.make(managedStatus: state, needsNewConversation: false, canStart: true, canRetry: false).action == nil)
        }
    }
}
