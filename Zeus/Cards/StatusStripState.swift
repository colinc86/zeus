import Foundation
import ZeusDesign
import ZeusProtocol

/// Snapshot-only mapping. No lifecycle action, clock mutation or reading side effect.
enum StatusStripState {
    struct Cards {
        var values: [Card]
        var seen: Set<String> = []
        var outgoing: [String: OutgoingMessageState] = [:]
        var pendingIDs: Set<String> = []
        var canClear = true
    }
    struct Status {
        var avatar: AvatarPresentation
        var deliveryProblem: Bool = false
        var quietUntil: String? = nil
    }
    struct Managed {
        var enabled = false
        var status: ManagedSessionStatus = .off
        var hasTerminal = false
        var canStartNew = false
    }
    enum Jump: Equatable {
        case question(String), unread(String), prompt(String), failed(String), latest, terminal
        var cardID: String? {
            switch self { case .question(let id), .unread(let id), .prompt(let id), .failed(let id): id; case .latest, .terminal: nil }
        }
    }
    static func isOpenQuestion(_ card: Card) -> Bool {
        card.status == .open && card.kind != .userMessage && (card.kind == .question || card.input != nil || !card.options.isEmpty)
    }
    static func isSkippable(_ card: Card) -> Bool {
        CardStore.canSkip(card)
    }
    static func ordered(_ cards: [Card]) -> [Card] {
        cards.enumerated().sorted {
            $0.element.createdAt == $1.element.createdAt ? $0.offset < $1.offset : $0.element.createdAt < $1.element.createdAt
        }.map(\.element)
    }
    static func questions(_ cards: Cards) -> [Card] { ordered(cards.values.filter(isOpenQuestion)) }
    static func unread(_ cards: Cards) -> [Card] { ordered(cards.values.filter { $0.kind != .userMessage && !cards.seen.contains($0.id) }) }
    static func mirroredPrompt(_ cards: Cards) -> Card? {
        ordered(cards.values.filter { $0.status == .open && $0.id.hasPrefix(ZeusRuntime.managedCardPrefix)
            && $0.options.contains { $0.id != "open-terminal" } }).last
    }
    static func failed(_ cards: Cards) -> Card? {
        let failed = ordered(cards.values.filter { card in
            guard card.kind == .userMessage, let state = cards.outgoing[card.id] else { return false }
            if case .failed = state { return true }; return false
        }).first
        if let failed { return failed }
        return ordered(cards.values.filter { card in
            if cards.pendingIDs.contains(card.id) { return true }
            if case .queued? = cards.outgoing[card.id] { return true }; return false
        }).first
    }
    static func jump(cards: Cards, status: Status, managed: Managed, activity: ConversationActivityPresentation?) -> Jump? {
        if managed.enabled, case .blocked = managed.status {
            return mirroredPrompt(cards).map { .prompt($0.id) } ?? (managed.hasTerminal ? .terminal : nil)
        }
        switch status.avatar.state {
        case .alert:
            if let first = unread(cards).first { return .unread(first.id) }
        case .waiting:
            if let first = questions(cards).first { return .question(first.id) }
        case .thinking, .working, .talking, .happy: return .latest
        default: break
        }
        if status.deliveryProblem { return failed(cards).map { .failed($0.id) } ?? .latest }
        return nil
    }
    static func make(cards: Cards, status: Status, managed: Managed, activity: ConversationActivityPresentation?) -> ZeusStatusStripModel {
        var buttons: [ZeusStatusStripModel.Item] = []
        if managed.hasTerminal { buttons.append(.init(.terminal)) }
        if managed.enabled { buttons.append(.init(.newConversation, isEnabled: managed.canStartNew)) }
        buttons += [.init(.clear, isEnabled: cards.canClear), .init(.settings)]
        if managed.enabled, case .blocked = managed.status {
            let mirrored = mirroredPrompt(cards) != nil
            return .init(glyph: .alert, sentence: mirrored ? "Waiting for your answer" : "Waiting for you in Terminal",
                         actionTitle: mirrored ? "Go to prompt" : managed.hasTerminal ? "Open" : nil, buttons: buttons)
        }
        switch status.avatar.state {
        case .alert:
            let count = unread(cards).count
            if count > 0 { return .init(glyph: .alert, sentence: count > 1 ? "\(count) unread" : "Unread", actionTitle: "Show", buttons: buttons) }
        case .waiting:
            let open = questions(cards)
            if let first = open.first {
                return .init(glyph: .question, sentence: open.count > 1 ? "\(open.count) questions" : "Waiting for your answer",
                             actionTitle: open.count > 1 ? "Go to oldest" : "Go to question",
                             skipTitle: isSkippable(first) ? "Skip" : nil, buttons: buttons)
            }
        case .thinking, .working:
            return .init(sentence: status.avatar.detail ?? activity?.label ?? (status.avatar.state == .working ? "Working…" : "Thinking…"), buttons: buttons)
        case .talking: return .init(sentence: "Zeus is talking…", buttons: buttons)
        case .happy:
            return .init(sentence: status.avatar.detail ?? status.avatar.state.rawValue.capitalized, buttons: buttons)
        default: break
        }
        if status.deliveryProblem { return .init(sentence: "Message not delivered", actionTitle: "Show", buttons: buttons) }
        if status.avatar.state == .sleeping { return .init(sentence: status.quietUntil.map { "Quiet until \($0)" } ?? "Quiet hours", isQuiet: true, buttons: buttons) }
        return .init(sentence: status.avatar.detail ?? "Idle", isQuiet: true, buttons: buttons)
    }
    static func nextQuestion(cards: Cards, after id: String?) -> String? {
        let ids = questions(cards).map(\.id)
        guard !ids.isEmpty else { return nil }
        guard let id, let index = ids.firstIndex(of: id) else { return ids.first }
        return ids[(index + 1) % ids.count]
    }
    static func firstControl(_ card: Card) -> ConversationControlTarget? {
        if let first = card.options.first { return .init(entryID: "card:\(card.id)", controlID: "option:\(first.id)") }
        if card.kind == .question, card.input != nil { return .init(entryID: "card:\(card.id)", controlID: "reply") }
        return nil
    }
    static func avatarTarget(cards: Cards, status: AvatarPresentation) -> Jump? {
        switch status.state {
        case .waiting: questions(cards).first.map { .question($0.id) }
        case .alert: unread(cards).first.map { .unread($0.id) }
        default: nil
        }
    }
}
