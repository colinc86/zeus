import Foundation
import Observation
import ZeusDesign
import ZeusProtocol

@MainActor @Observable
final class ConversationPanelState {
    var isVisible = false
    var focusRequest = 0
    var scrollTargetCardID: String?
    var focusScrollTarget = false
    var scrollRequest = 0
    var atBottom = true
    #if DEBUG || ZEUS_PERFORMANCE_PROBE
    @ObservationIgnored var scrollPhasesForDiagnostics: [String] = []
    @ObservationIgnored var activityRowVisibleForDiagnostics = false
    @ObservationIgnored var viewportForDiagnostics = ConversationViewport()
    @ObservationIgnored var newestMessageTopForDiagnostics: CGFloat?
    @ObservationIgnored var latestButtonVisibleForDiagnostics = false
    @ObservationIgnored var newestMessageFrameForDiagnostics: CGRect?
    @ObservationIgnored var focusedControlForDiagnostics: ConversationControlTarget?
    #endif
    /// Native input provenance; pointer focus must not move a control before mouse-up.
    @ObservationIgnored var focusCameFromPointer = false
    var composerFocused = false
    var keyboardScroll: ConversationScrollCommand?
    var keyboardScrollRequest = 0
    var tail: ZeusDialogTail?
    var screenHeight: CGFloat = 900
    var height: CGFloat = 250
    var width: CGFloat = ZeusTheme.Conversation.panelWidth
}

/// Pure presentation rules shared by the thread and its tests.
enum ConversationLayout {
    static let pageSize = 300
    static func grouped(_ entry: ConversationEntry, after previous: ConversationEntry?, cards: [Card]) -> Bool {
        grouped(entry, after: previous, sources: Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0) }))
    }
    static func grouped(_ entry: ConversationEntry, after previous: ConversationEntry?, sources: [String: Card]) -> Bool {
        guard let previous, entry.isUser == previous.isUser, !entry.isNotice, !previous.isNotice,
              entry.timestamp.timeIntervalSince(previous.timestamp) < 120,
              Calendar.current.isDate(entry.timestamp, inSameDayAs: previous.timestamp) else { return false }
        return sources[entry.sourceCardID]?.sessionKey == sources[previous.sourceCardID]?.sessionKey
    }
    static func session(_ entry: ConversationEntry, cards: [Card]) -> String? {
        cards.first { $0.id == entry.sourceCardID }?.sessionKey
    }
    static func needsDivider(_ entry: ConversationEntry, after previous: ConversationEntry?, calendar: Calendar = .current) -> Bool {
        guard let previous else { return true }
        return entry.timestamp.timeIntervalSince(previous.timestamp) > 600 || !calendar.isDate(entry.timestamp, inSameDayAs: previous.timestamp)
    }
    static func divider(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = date.formatted(.dateTime.hour().minute())
        if calendar.isDate(date, inSameDayAs: now) { return "Today \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday \(time)" }
        let style: Date.FormatStyle = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            ? .dateTime.weekday(.abbreviated).day().month(.abbreviated) : .dateTime.day().month(.abbreviated).year()
        return "\(date.formatted(style)) \(time)"
    }
    static func sessionLabel(key: String, sessions: [ConnectedSession]) -> String {
        SessionLabels.displayLabel(key: key, sessions: sessions)
    }

    /// Replies do not restart a session run. Dividers reset it, even before a user bubble.
    static func sessionLabelEntries(_ entries: [ConversationEntry], cards: [Card]) -> Set<String> {
        let sources = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0) })
        guard Set(entries.compactMap { sources[$0.sourceCardID]?.sessionKey }).count > 1 else { return [] }
        var previousSession: String?
        var previousEntry: ConversationEntry?
        var labels: Set<String> = []
        for entry in entries {
            if needsDivider(entry, after: previousEntry) { previousSession = nil }
            previousEntry = entry
            guard !entry.isUser, !entry.isNotice else { continue }
            let key = sources[entry.sourceCardID]?.sessionKey
            if let key, key != previousSession { labels.insert(entry.id) }
            previousSession = key
        }
        return labels
    }

    static func answerCaption(_ entry: ConversationEntry, after previous: ConversationEntry?, cards: [Card]) -> String? {
        answerCaption(entry, after: previous, sources: Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0) }))
    }
    static func answerCaption(_ entry: ConversationEntry, after previous: ConversationEntry?, sources: [String: Card]) -> String? {
        guard case .userAnswer(let cardID, _) = entry.content, previous?.sourceCardID != cardID,
              let source = sources[cardID] else { return nil }
        return source.title ?? String(source.body.prefix(40))
    }
    static func accessibilityLabel(_ entry: ConversationEntry, sessions: [ConnectedSession]) -> String {
        let speaker: String
        var title: String?
        if case .agentCard(let card) = entry.content {
            speaker = Self.speaker(card, sessions: sessions)
            title = card.title
        } else { speaker = "You" }
        return [speaker, title, entry.timestamp.formatted(.dateTime.hour().minute())]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }
    /// The agent's short name ("Claude"), or "Zeus" for Zeus's own cards (D2-8).
    static func speaker(_ card: Card, sessions: [ConnectedSession]) -> String {
        let agent = sessions.first { $0.sessionKey == card.sessionKey }?.agent
            ?? card.sessionKey?.split(separator: ":", maxSplits: 1).first.flatMap { AgentKind(rawValue: String($0)) }
        return agent.map(ZeusAgentName.short) ?? "Zeus"
    }

    static func threadHeight(content: CGFloat, composer: CGFloat, screen: CGFloat, strip: CGFloat = 0) -> CGFloat {
        let maximum = min(ZeusTheme.Conversation.maxThreadHeight, screen * ZeusTheme.Conversation.maxHeightFraction - composer - strip - 54 - ZeusDialogTail.height)
        return min(max(content, ZeusTheme.Conversation.minThreadHeight), max(0, maximum))
    }
    static func unseenBelow(entries: [ConversationEntry], visible: Set<String>, seen: Set<String>) -> Int {
        guard let lastVisible = entries.lastIndex(where: { visible.contains($0.id) }) else { return 0 }
        return entries.dropFirst(lastVisible + 1).filter { !$0.isUser && !$0.isNotice && !$0.isRatingHeld && !seen.contains($0.sourceCardID) }.count
    }
    static func isAtBottom(lastBottom: CGFloat, viewportHeight: CGFloat) -> Bool { lastBottom <= viewportHeight + 24 }
    static func intersects(_ frame: CGRect, viewportHeight: CGFloat) -> Bool { frame.maxY > 0 && frame.minY < viewportHeight }
    static func hotKeyCloses(isVisible: Bool, isKey: Bool) -> Bool { isVisible && isKey }
}

/// Focus identities are unique across cards even when agents reuse option/attachment IDs.
struct ConversationControlTarget: Hashable {
    let entryID: String
    let controlID: String
}
