import Foundation

/// The avatar's eight animation states.
public enum AvatarState: String, Codable, Sendable, CaseIterable {
    case idle, talking, thinking, working, alert, waiting, happy, sleeping
    /// Next state to try when a character lacks this animation.
    public var fallback: AvatarState? {
        switch self { case .idle: nil; case .working: .thinking; case .waiting: .alert; default: .idle }
    }
}
/// The agent backend associated with a bridge.
public enum AgentKind: String, Codable, Sendable, CaseIterable { case claude, codex, opencode, other }

/// An actionable choice on a card.
public struct CardOption: Codable, Sendable, Equatable {
    /// Stable identifier for this value.
    public var id: String
    /// Human-readable text displayed to the user.
    public var label: String
    /// Visual intent; secondary is the default.
    public var style: Style

    /// Creates CardOption.
    public init(id: String, label: String, style: Style = .secondary) {
        self.id = id
        self.label = label
        self.style = style
    }
    /// Visual intent of an option.
    public enum Style: String, Codable, Sendable, CaseIterable { case primary, secondary, destructive }
}

/// Optional free-text input configuration.
public struct InputSpec: Codable, Sendable, Equatable {
    /// Hint displayed while the input is empty.
    public var placeholder: String?
    /// Whether the user may enter multiple lines.
    public var multiline: Bool

    /// Creates InputSpec.
    public init(placeholder: String? = nil, multiline: Bool = false) {
        self.placeholder = placeholder
        self.multiline = multiline
    }
}

/// A file, directory or URL the user can open.
public struct Attachment: Codable, Sendable, Equatable {
    /// Stable identifier for this value.
    public var id: String
    /// Category serialized as its camelCase raw string.
    public var kind: Kind
    /// Human-readable text displayed to the user.
    public var label: String
    /// File or directory path (including ~), or URL string.
    public var target: String

    /// Assistant-written synopsis; absent on legacy attachments and optional for links.
    public var summary: String?

    /// Creates Attachment.
    public init(id: String = UUID().uuidString, kind: Kind, label: String, target: String, summary: String? = nil) {
        self.id = id
        self.kind = kind
        self.label = label
        self.target = target
        self.summary = summary
    }
    /// How the attachment target is interpreted.
    public enum Kind: String, Codable, Sendable, CaseIterable { case file, folder, url }
}

/// A user answer from either device.
public struct CardResponse: Codable, Sendable, Equatable {
    /// Identifier of the selected option, if any.
    public var optionID: String?
    /// Display label of the selected option, if any.
    public var optionLabel: String?
    /// Optional free-text answer.
    public var text: String?
    /// Time the user submitted the answer.
    public var respondedAt: Date
    /// Device where the answer originated.
    public var device: Device
    /// The user chose to move on without answering; absent in older snapshots means false.
    public var skipped: Bool

    /// Creates CardResponse.
    public init(optionID: String? = nil, optionLabel: String? = nil, text: String? = nil, respondedAt: Date = Date(), device: Device, skipped: Bool = false) {
        self.optionID = optionID
        self.optionLabel = optionLabel
        self.text = text
        self.respondedAt = respondedAt
        self.device = device
        self.skipped = skipped
    }
    private enum CodingKeys: String, CodingKey { case optionID, optionLabel, text, respondedAt, device, skipped }
    /// Decodes responses saved before the Skip action existed.
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        optionID = try fields.decodeIfPresent(String.self, forKey: .optionID)
        optionLabel = try fields.decodeIfPresent(String.self, forKey: .optionLabel)
        text = try fields.decodeIfPresent(String.self, forKey: .text)
        respondedAt = try fields.decode(Date.self, forKey: .respondedAt)
        device = try fields.decode(Device.self, forKey: .device)
        skipped = try fields.decodeIfPresent(Bool.self, forKey: .skipped) ?? false
    }
    /// Device on which the answer was submitted.
    public enum Device: String, Codable, Sendable, CaseIterable { case mac, ios }
    /// Human-readable option label and nonempty free text, separated by a newline.
    public var summary: String {
        [optionLabel, text].compactMap { value in
            guard let value, !value.isEmpty else { return nil }; return value
        }.joined(separator: "\n")
    }
}

/// Shared card state for the Mac and iOS clients.
/// Runtime-classified source. Agents cannot choose this value.
public enum CardOrigin: String, Codable, Sendable { case reply, unprompted }
/// Persisted explanation of a local rating or daily-budget hold. A release never replays a notification.
public struct CardMuteDecision: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable { case rating, dailyBudget }
    /// Missing on legacy records, which are rating decisions.
    public var source: Source?
    public var ratingID: String
    public var kindLabel: String
    public var reason: String
    public var engine: String
    public var score: Double
    public var threshold: Double
    public var decidedAt: Date
    public var releasedAt: Date?
    public init(ratingID: String, kindLabel: String, reason: String, engine: String, score: Double, threshold: Double, decidedAt: Date, releasedAt: Date? = nil, source: Source? = nil) {
        self.source = source
        self.ratingID = ratingID; self.kindLabel = kindLabel; self.reason = reason; self.engine = engine
        self.score = score; self.threshold = threshold; self.decidedAt = decidedAt; self.releasedAt = releasedAt
    }
}

public struct Card: Codable, Sendable, Equatable, Identifiable {
    /// Stable identifier for this value.
    public var id: String
    /// Category serialized as its camelCase raw string.
    public var kind: Kind
    /// Optional heading displayed above the body.
    public var title: String?
    /// Markdown body displayed by card clients.
    public var body: String
    /// Choices displayed in their supplied order.
    public var options: [CardOption]
    /// Free-text input configuration, or nil to hide it.
    public var input: InputSpec?
    /// Files, directories and links associated with the card.
    public var attachments: [Attachment]
    /// Progress from 0 through 1, or nil for indeterminate progress.
    public var progress: Double?
    /// Ordering priority; normal is the default.
    public var priority: Priority
    /// Optional avatar animation associated with the card.
    public var mood: AvatarState?
    /// Stable originating session identity, used for reply routing.
    public var sessionKey: String?
    /// Assistant's short kind label, validated by Zeus. Nil on legacy/local cards.
    public var about: String?
    /// Nil on legacy/local cards: never infer that those are unprompted.
    public var origin: CardOrigin?
    /// Published before add/onAdd so a held card never produces an alert.
    public var muteDecision: CardMuteDecision?
    /// Creation time, serialized as ISO-8601.
    public var createdAt: Date
    /// Most recent card modification time, serialized as ISO-8601.
    public var updatedAt: Date
    /// Optional expiry time, serialized as ISO-8601.
    public var expiresAt: Date?
    /// Current card lifecycle state.
    public var status: Status
    /// Submitted answer, when the card has been answered.
    public var response: CardResponse?

    /// Creates Card.
    public init(id: String = "c_" + UUID().uuidString.prefix(8).lowercased(), kind: Kind, title: String? = nil, body: String, options: [CardOption] = [], input: InputSpec? = nil, attachments: [Attachment] = [], progress: Double? = nil, priority: Priority = .normal, mood: AvatarState? = nil, sessionKey: String? = nil, createdAt: Date = Date(), updatedAt: Date = Date(), expiresAt: Date? = nil, status: Status = .open, response: CardResponse? = nil, about: String? = nil, origin: CardOrigin? = nil, muteDecision: CardMuteDecision? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.options = options
        self.input = input
        self.attachments = attachments
        self.progress = progress
        self.priority = priority
        self.mood = mood
        self.sessionKey = sessionKey
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.expiresAt = expiresAt
        self.status = status
        self.response = response
        self.about = about; self.origin = origin; self.muteDecision = muteDecision
    }
    /// Content category of a card.
    public enum Kind: String, Codable, Sendable, CaseIterable { case message, question, content, progress, userMessage }
    /// Card ordering priority.
    public enum Priority: String, Codable, Sendable, CaseIterable { case low, normal, high }
    /// Card lifecycle state.
    public enum Status: String, Codable, Sendable, CaseIterable { case open, answered, dismissed, expired }
}

/// Persisted, deduplicated agent delivery; pushWritten is not an acknowledgment.
public struct Delivery: Codable, Sendable, Equatable, Identifiable {
    /// Stable identifier for this value.
    public var id: String
    /// Category serialized as its camelCase raw string.
    public var kind: Kind
    /// Originating card identifier for a reply; nil for a user message.
    public var cardID: String?
    /// Stable destination identity computed from the bridge hello.
    public var sessionKey: String
    /// Human-readable user input sent to the agent.
    public var content: String
    /// Channel metadata; delivery keys use letters, digits and underscores.
    public var meta: [String: String]
    /// Creation time, serialized as ISO-8601.
    public var createdAt: Date
    /// Number of send attempts made so far.
    public var attempts: Int
    /// Time of the latest send attempt, if any.
    public var lastAttemptAt: Date?
    /// Time an agent acknowledgment was recorded, if any.
    public var ackedAt: Date?
    /// Time delivery attempts were exhausted, if any.
    public var failedAt: Date?

    /// Creates Delivery.
    public init(id: String = "d_" + UUID().uuidString.prefix(8).lowercased(), kind: Kind, cardID: String? = nil, sessionKey: String, content: String, meta: [String: String] = [:], createdAt: Date = Date(), attempts: Int = 0, lastAttemptAt: Date? = nil, ackedAt: Date? = nil, failedAt: Date? = nil) {
        self.id = id
        self.kind = kind
        self.cardID = cardID
        self.sessionKey = sessionKey
        self.content = content
        self.meta = meta
        self.createdAt = createdAt
        self.attempts = attempts
        self.lastAttemptAt = lastAttemptAt
        self.ackedAt = ackedAt
        self.failedAt = failedAt
    }
    /// Whether the delivery answers a card or starts a conversation.
    public enum Kind: String, Codable, Sendable, CaseIterable { case reply, userMessage, reflection, learning }
}

