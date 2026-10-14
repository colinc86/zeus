import Foundation

/// Current NDJSON wire revision.
public let wireVersion = 1

/// Bridge-to-app handshake describing one bridge process.
public struct BridgeHello: Codable, Sendable, Equatable {
    /// NDJSON protocol revision; defaults to the current supported revision.
    public var wireVersion: Int
    /// UUID identifying this bridge process, retained across socket reconnects.
    public var bridgeID: UUID
    /// Agent backend associated with the bridge.
    public var agent: AgentKind
    /// Bridge process ID.
    public var pid: Int
    /// Parent process ID.
    public var ppid: Int
    /// Agent process start time, in microseconds since the Unix epoch. PID reuse creates a new key.
    public var parentStartTime: UInt64
    /// Session working directory, used verbatim in the stable session key.
    public var cwd: String
    /// Name and version received from MCP initialize.
    public var client: Client
    /// Delivery capabilities offered by this bridge.
    public var capabilities: Capabilities
    /// Optional TMUX_PANE value for the tmux connector; never part of routing identity.
    public var tmuxPane: String?
    /// tmux server socket namespace paired with tmuxPane; never routing identity.
    public var tmuxSocketPath: String?

    private enum CodingKeys: String, CodingKey {
        case wireVersion, bridgeID, agent, pid, ppid, parentStartTime, cwd, client, capabilities, tmuxPane, tmuxSocketPath
    }
    /// Decode an older hello far enough to send an actionable upgrade error.
    /// The server rejects a missing/zero start time instead of assigning a collision-prone identity.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        wireVersion = try c.decode(Int.self, forKey: .wireVersion)
        bridgeID = try c.decode(UUID.self, forKey: .bridgeID)
        agent = try c.decode(AgentKind.self, forKey: .agent)
        pid = try c.decode(Int.self, forKey: .pid); ppid = try c.decode(Int.self, forKey: .ppid)
        parentStartTime = try c.decodeIfPresent(UInt64.self, forKey: .parentStartTime) ?? 0
        cwd = try c.decode(String.self, forKey: .cwd)
        client = try c.decode(Client.self, forKey: .client)
        capabilities = try c.decode(Capabilities.self, forKey: .capabilities)
        tmuxPane = try c.decodeIfPresent(String.self, forKey: .tmuxPane)
        tmuxSocketPath = try c.decodeIfPresent(String.self, forKey: .tmuxSocketPath)
    }

    /// Creates BridgeHello.
    public init(wireVersion: Int = ZeusProtocol.wireVersion, bridgeID: UUID = UUID(), agent: AgentKind, pid: Int, ppid: Int, cwd: String, client: Client, capabilities: Capabilities, tmuxPane: String? = nil, parentStartTime: UInt64 = 0, tmuxSocketPath: String? = nil) {
        self.wireVersion = wireVersion
        self.bridgeID = bridgeID
        self.agent = agent
        self.pid = pid
        self.ppid = ppid
        self.parentStartTime = parentStartTime
        self.cwd = cwd
        self.client = client
        self.capabilities = capabilities
        self.tmuxPane = tmuxPane; self.tmuxSocketPath = tmuxSocketPath
    }
    /// Stable routing identity; newest connected bridge with this key wins.
    public var sessionKey: String { "\(agent.rawValue):\(cwd)#\(ppid).\(parentStartTime)" }
    /// MCP initialize client metadata.
    public struct Client: Codable, Sendable, Equatable {
        /// MCP client or requested tool name.
        public var name: String
        /// MCP client version.
        public var version: String
    
        /// Creates Client.
        public init(name: String, version: String) {
            self.name = name
            self.version = version
        }
    }
    
    /// Bridge delivery capabilities.
    public struct Capabilities: Codable, Sendable, Equatable {
        /// Whether the bridge supports Claude channel notifications.
        public var channel: Bool
        /// Reports tool results only after the MCP stdout frame has been flushed.
        public var toolResultWritten: Bool
        /// Understands the additive digest/moment notification. Older bridges default to false.
        public var learningNotifications: Bool
        private enum CodingKeys: String, CodingKey { case channel, toolResultWritten, learningNotifications }
        /// Older bridges do not offer stdout receipts.
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            channel = try c.decode(Bool.self, forKey: .channel)
            toolResultWritten = try c.decodeIfPresent(Bool.self, forKey: .toolResultWritten) ?? false
            learningNotifications = try c.decodeIfPresent(Bool.self, forKey: .learningNotifications) ?? false
        }
    
        /// Creates Capabilities.
        public init(channel: Bool = false, toolResultWritten: Bool = false, learningNotifications: Bool = false) {
            self.channel = channel; self.toolResultWritten = toolResultWritten
            self.learningNotifications = learningNotifications
        }
    }
    
}

/// App-to-bridge handshake acceptance.
public struct BridgeWelcome: Codable, Sendable, Equatable {
    /// NDJSON protocol revision; defaults to the current supported revision.
    public var wireVersion: Int
    /// Stable routing identity computed by the app.
    public var sessionKey: String
    /// Mac app version string.
    public var appVersion: String
    /// Negotiated tool-result stdout receipts; absent in older app versions.
    public var toolResultWritten: Bool
    private enum CodingKeys: String, CodingKey { case wireVersion, sessionKey, appVersion, toolResultWritten }
    /// Accepts older welcome frames without receipt negotiation.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        wireVersion = try c.decode(Int.self, forKey: .wireVersion)
        sessionKey = try c.decode(String.self, forKey: .sessionKey)
        appVersion = try c.decode(String.self, forKey: .appVersion)
        toolResultWritten = try c.decodeIfPresent(Bool.self, forKey: .toolResultWritten) ?? false
    }

    /// Creates BridgeWelcome.
    public init(wireVersion: Int = ZeusProtocol.wireVersion, sessionKey: String, appVersion: String, toolResultWritten: Bool = false) {
        self.wireVersion = wireVersion
        self.sessionKey = sessionKey
        self.appVersion = appVersion; self.toolResultWritten = toolResultWritten
    }
}

/// An agent tool request forwarded to the app.
public struct ToolCall: Codable, Sendable, Equatable {
    /// Unique correlation ID identifying the pending tool request.
    public var callID: String
    /// MCP client or requested tool name.
    public var name: String
    /// Snake_case MCP tool arguments.
    public var arguments: JSONValue

    /// Creates ToolCall.
    public init(callID: String = UUID().uuidString, name: String, arguments: JSONValue = [:]) {
        self.callID = callID
        self.name = name
        self.arguments = arguments
    }
}

/// The text and optional structured result visible to the model.
public struct ToolResult: Codable, Sendable, Equatable {
    /// Model-visible compact JSON result text, or a human-readable error.
    public var text: String
    /// Optional structured JSON content matching the model-visible text.
    public var structured: JSONValue?
    /// Whether this result reports a failed tool call.
    public var isError: Bool

    /// Creates ToolResult.
    public init(text: String, structured: JSONValue? = nil, isError: Bool = false) {
        self.text = text
        self.structured = structured
        self.isError = isError
    }
    /// Creates matching compact JSON text and structured content.
    public init(structured: JSONValue, isError: Bool = false) throws {
        self.init(text: String(decoding: try ZeusJSON.encoder().encode(structured), as: UTF8.self), structured: structured, isError: isError)
    }
}

/// App-to-bridge result correlated with its request.
public struct BridgeToolResult: Codable, Sendable, Equatable {
    /// Unique correlation ID identifying the pending tool request.
    public var callID: String
    /// Model-visible compact JSON result text, or a human-readable error.
    public var text: String
    /// Optional structured JSON content matching the model-visible text.
    public var structured: JSONValue?
    /// Whether this result reports a failed tool call.
    public var isError: Bool

    /// Creates BridgeToolResult.
    public init(callID: String, text: String, structured: JSONValue? = nil, isError: Bool = false) {
        self.callID = callID
        self.text = text
        self.structured = structured
        self.isError = isError
    }
    /// Wraps a delegate result in its wire correlation ID.
    public init(callID: String, result: ToolResult) { self.init(callID: callID, text: result.text, structured: result.structured, isError: result.isError) }
    /// Delegate-facing result without wire correlation data.
    public var result: ToolResult { .init(text: text, structured: structured, isError: isError) }
}

/// Human-readable delivery into an agent session.
public struct AgentPush: Codable, Sendable, Equatable {
    /// Stable delivery identity used for deduplication and receipts.
    public var deliveryID: String
    /// Human-readable reply or user message.
    public var content: String
    /// Channel metadata, including kind and delivery_id.
    public var meta: [String: String]

    /// Creates AgentPush.
    public init(deliveryID: String, content: String, meta: [String: String] = [:]) {
        self.deliveryID = deliveryID
        self.content = content
        self.meta = meta
    }
}

/// Receipt that a channel notification reached stdout, not the model.
public struct PushWritten: Codable, Sendable, Equatable {
    /// Stable delivery identity used for deduplication and receipts.
    public var deliveryID: String

    /// Creates PushWritten.
    public init(deliveryID: String) {
        self.deliveryID = deliveryID
    }
}

/// Receipt that a tool result was flushed to MCP stdout.
public struct ToolResultWritten: Codable, Sendable, Equatable {
    /// The original tool request correlation ID.
    public var callID: String
    /// Creates a stdout receipt.
    public init(callID: String) { self.callID = callID }
}

/// A protocol or transport error sent to the peer.
public struct BridgeError: Codable, Sendable, Equatable {
    /// Human-readable explanation of a protocol error.
    public var message: String

    /// Creates BridgeError.
    public init(message: String) {
        self.message = message
    }
}

/// A different bridge claimed this agent-process identity. The recipient must
/// stop automatic reconnects and wait for its own next tools/call before retrying.
public struct BridgeSuperseded: Codable, Sendable, Equatable {
    /// The agent-process session whose transport was replaced.
    public var sessionKey: String
    /// Creates an explicit eviction notice.
    public init(sessionKey: String) { self.sessionKey = sessionKey }
}

/// A digest/moment notification. No raw activity data can cross this typed boundary.
public struct BridgeLearning: Codable, Sendable, Equatable {
    /// Only digests and moments are eligible to leave the local store.
    public enum Kind: String, Codable, Sendable { case digest, moment }
    /// Stable store identity; announcements do not commit read state.
    public let id: String
    /// Whether this is a daily summary or a timely moment.
    public let kind: Kind
    /// The exact derived summary, with no raw-event fields.
    public let text: String
    /// Creates a derived-learning announcement.
    public init(id: String, kind: Kind, text: String) { self.id = id; self.kind = kind; self.text = text }
}

/// Flat wire envelope, discriminated by the JSON `type` member.
public enum WireMessage: Codable, Sendable, Equatable {
    case hello(BridgeHello)
    case welcome(BridgeWelcome)
    case toolCall(ToolCall)
    case toolResult(BridgeToolResult)
    case push(AgentPush)
    case pushWritten(PushWritten)
    case toolResultWritten(ToolResultWritten)
    case error(BridgeError)
    case superseded(BridgeSuperseded)
    case learning(BridgeLearning)
    case turnEnded(TurnEnded)
    case turnEndedReceipt(TurnEndedReceipt)
    private enum CodingKeys: String, CodingKey { case type }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "hello": self = .hello(try BridgeHello(from: decoder))
        case "welcome": self = .welcome(try BridgeWelcome(from: decoder))
        case "toolCall": self = .toolCall(try ToolCall(from: decoder))
        case "toolResult": self = .toolResult(try BridgeToolResult(from: decoder))
        case "push": self = .push(try AgentPush(from: decoder))
        case "pushWritten": self = .pushWritten(try PushWritten(from: decoder))
        case "toolResultWritten": self = .toolResultWritten(try ToolResultWritten(from: decoder))
        case "error": self = .error(try BridgeError(from: decoder))
        case "superseded": self = .superseded(try BridgeSuperseded(from: decoder))
        case "learning": self = .learning(try BridgeLearning(from: decoder))
        case "turnEnded": self = .turnEnded(try TurnEnded(from: decoder))
        case "turnEndedReceipt": self = .turnEndedReceipt(try TurnEndedReceipt(from: decoder))
        default: throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown wire type: \(type)")
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hello(let value): try container.encode("hello", forKey: .type); try value.encode(to: encoder)
        case .welcome(let value): try container.encode("welcome", forKey: .type); try value.encode(to: encoder)
        case .toolCall(let value): try container.encode("toolCall", forKey: .type); try value.encode(to: encoder)
        case .toolResult(let value): try container.encode("toolResult", forKey: .type); try value.encode(to: encoder)
        case .push(let value): try container.encode("push", forKey: .type); try value.encode(to: encoder)
        case .pushWritten(let value): try container.encode("pushWritten", forKey: .type); try value.encode(to: encoder)
        case .toolResultWritten(let value): try container.encode("toolResultWritten", forKey: .type); try value.encode(to: encoder)
        case .error(let value): try container.encode("error", forKey: .type); try value.encode(to: encoder)
        case .superseded(let value): try container.encode("superseded", forKey: .type); try value.encode(to: encoder)
        case .learning(let value): try container.encode("learning", forKey: .type); try value.encode(to: encoder)
        case .turnEnded(let value): try container.encode("turnEnded", forKey: .type); try value.encode(to: encoder)
        case .turnEndedReceipt(let value): try container.encode("turnEndedReceipt", forKey: .type); try value.encode(to: encoder)
        }
    }
}
