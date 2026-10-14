import ZeusProtocol

/// A size in sprite pixels.
public struct PixelSize: Sendable, Hashable, Codable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// A point in sprite pixels. The origin is the top-left corner and `y` grows downward.
public struct PixelPoint: Sendable, Hashable, Codable {
    public var x: Int
    public var y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }
}

extension AvatarState {
    /// Every state in a stable display order. Spelled out (rather than `CaseIterable`) so it
    /// doesn't depend on which conformances `ZeusProtocol.AvatarState` declares.
    public static let spriteOrder: [AvatarState] = [
        .idle, .talking, .thinking, .working, .alert, .waiting, .happy, .sleeping,
    ]

    /// The key used for this state in character JSON (`"idle"`, `"talking"`, …).
    public var spriteKey: String {
        switch self {
        case .idle: "idle"
        case .talking: "talking"
        case .thinking: "thinking"
        case .working: "working"
        case .alert: "alert"
        case .waiting: "waiting"
        case .happy: "happy"
        case .sleeping: "sleeping"
        }
    }

    /// Looks up a state by its JSON key.
    public init?(spriteKey: String) {
        guard let state = Self.spriteOrder.first(where: { $0.spriteKey == spriteKey }) else { return nil }
        self = state
    }
}
