import Foundation
import Observation
import ZeusProtocol
import ZeusDesign

struct AvatarPresentation: Equatable {
    var state: AvatarState
    var detail: String? = nil
    var progress: Double? = nil
}

/// Resolves CONTRACT §7 in priority order; the supplied clock makes deadline boundaries testable.
@MainActor
@Observable
final class AvatarStatusModel: AvatarStatusControlling, ManagedBlockingPresenting {
    @ObservationIgnored private(set) var now: Date
    private var clockPresentation = AvatarPresentation(state: .idle)
    private var clockActivity: AvatarPresentation?
    private(set) var deliveryProblem: String?
    private var managedBlockDetail: String?
    private var transientState: AvatarState?
    private var speakingUntil: Date?
    private var speakingCardID: String?
    private var transientUntil: Date?
    private var override: AvatarPresentation?
    private var overrideUntil: Date?
    @ObservationIgnored private let cards: CardStore
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let assistantActivity: () -> AssistantActivity?
    @ObservationIgnored private let quietHours: (Date) -> Bool

    init(cards: CardStore, clock: @escaping () -> Date = Date.init,
         quietHours: @escaping (Date) -> Bool = { _ in false },
         assistantActivity: @escaping () -> AssistantActivity? = { nil }) {
        self.cards = cards
        self.clock = clock
        self.quietHours = quietHours
        self.assistantActivity = assistantActivity
        now = clock()
        tick()
    }

    var presentation: AvatarPresentation {
        _ = clockPresentation
        return resolve(at: now)
    }
    var activity: AvatarPresentation? {
        _ = clockActivity
        return resolveActivity(at: now)
    }
    private func resolveActivity(at date: Date) -> AvatarPresentation? {
        guard let override, let overrideUntil, date < overrideUntil,
              override.state == .thinking || override.state == .working else { return nil }
        return override
    }
    var state: AvatarState { presentation.state }
    var openCount: Int { cards.openCards.count }
    /// A5b uses this for the avatar badge instead of the legacy open-card count.
    var badgeCount: Int { cards.unseenCount }

    /// No observable clock tick: publish only a changed time-dependent presentation.
    func tick() {
        now = clock()
        let presentation = resolve(at: now)
        let activity = resolveActivity(at: now)
        if clockPresentation != presentation { clockPresentation = presentation }
        if clockActivity != activity { clockActivity = activity }
    }

    var nextDeadline: Date? {
        [speakingUntil, transientUntil, overrideUntil].compactMap { $0 }.filter { $0 > now }.min()
    }

    func noteNewCard(_ card: Card) {
        now = clock()
        speakingUntil = nil
        speakingCardID = nil
        transientState = card.mood ?? .talking
        transientUntil = now.addingTimeInterval(2.5)
        tick()
    }

    /// Peek speech has the exact same duration as D8's reveal; the card mood follows the last word.
    func notePeek(_ card: Card, reduceMotion: Bool, typewriter: Bool = true) {
        now = clock()
        let typing = typewriter && !reduceMotion
        let duration = typing
            ? ZeusPeekTiming.talkingDuration(length: ZeusPeekTiming.typedLength(card.body), reduceMotion: false)
            : ZeusPeekTiming.talkingDuration(length: 0, reduceMotion: true)
        speakingCardID = card.id
        speakingUntil = now.addingTimeInterval(duration)
        transientState = card.mood
        transientUntil = now.addingTimeInterval(max(2.5, duration))
        tick()
    }
    func stopPeekSpeech(cardID: String) {
        guard speakingCardID == cardID else { return }
        speakingUntil = nil
        speakingCardID = nil
        transientState = nil
        transientUntil = nil
        tick()
    }

    func setOverride(_ state: AvatarState, detail: String?, progress: Double?, ttl: TimeInterval) {
        now = clock()
        override = AvatarPresentation(state: state, detail: detail,
                                      progress: progress.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil })
        overrideUntil = now.addingTimeInterval(ttl.isFinite ? max(0, ttl) : 0)
        tick()
    }

    func clearOverride() {
        override = nil
        overrideUntil = nil
        tick()
    }

    func setManagedBlock(_ detail: String?) {
        managedBlockDetail = detail
        tick()
    }

    func setDeliveryProblem(_ message: String?) { deliveryProblem = message }

    func resolve(at date: Date) -> AvatarPresentation {
        if let managedBlockDetail { return AvatarPresentation(state: .alert, detail: managedBlockDetail) }
        if let speakingUntil, date < speakingUntil { return AvatarPresentation(state: .talking) }
        if let transientState, let transientUntil, date < transientUntil, attentionStateAllowed(transientState) {
            return AvatarPresentation(state: transientState)
        }
        if let override, let overrideUntil, date < overrideUntil, attentionStateAllowed(override.state) { return override }
        if cards.hasUnseenCards { return AvatarPresentation(state: .alert) }
        if let activity = assistantActivity() {
            return AvatarPresentation(state: activity.phase == .working ? .working : .thinking, detail: activity.detail,
                                      progress: activity.progress.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil })
        }
        if cards.hasOpenQuestion { return AvatarPresentation(state: .waiting) }
        if quietHours(date) { return AvatarPresentation(state: .sleeping) }
        return AvatarPresentation(state: .idle)
    }

    private func attentionStateAllowed(_ state: AvatarState) -> Bool {
        switch state {
        case .alert: return !cards.isConversationOpen && cards.hasUnseenCards
        case .waiting: return cards.hasOpenQuestion
        default: return true
        }
    }
}
