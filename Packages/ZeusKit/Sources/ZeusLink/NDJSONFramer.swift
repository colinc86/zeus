import Foundation
import ZeusProtocol

/// Errors raised by the socket link or NDJSON framing.
public enum BridgeLinkError: Error, Sendable, Equatable, LocalizedError {
    case system(operation: String, code: Int32)
    case invalidSocketPath
    case socketAlreadyExists
    case messageTooLarge
    case invalidUTF8
    case truncatedMessage
    case protocolViolation(String)
    case disconnected
    case timeout
    case stopped

    public var errorDescription: String? {
        switch self {
        case .system(let operation, let code): "\(operation) failed (errno \(code))"
        case .invalidSocketPath: "Unix socket path is empty, contains NUL, or exceeds sun_path capacity"
        case .socketAlreadyExists: "Socket path already exists; refusing to replace another listener or file"
        case .messageTooLarge: "NDJSON frame exceeds its byte limit"
        case .invalidUTF8: "NDJSON frame is not valid UTF-8"
        case .truncatedMessage: "Connection ended inside an NDJSON frame"
        case .protocolViolation(let reason): "Bridge protocol violation: \(reason)"
        case .disconnected: "Bridge disconnected"
        case .timeout: "Bridge operation timed out"
        case .stopped: "Bridge stopped"
        }
    }
}

/// Incremental byte framing. UTF-8 is decoded only after a complete newline-delimited frame.
public struct NDJSONFramer: Sendable {
    /// Maximum bytes in one JSON frame (excluding its newline).
    public let maximumFrameBytes: Int
    private var buffer = Data()
    /// Creates a framer with a bounded buffer; default accommodates rich cards.
    public init(maximumFrameBytes: Int = 4 * 1024 * 1024) {
        self.maximumFrameBytes = max(1, maximumFrameBytes)
    }
    /// Consumes a byte chunk and returns all completed messages, in wire order.
    public mutating func append(_ bytes: Data) throws -> [WireMessage] {
        var messages: [WireMessage] = []
        // Process pieces individually so a large read of many small frames does not hit the per-frame limit.
        var start = bytes.startIndex
        while let newline = bytes[start...].firstIndex(of: 10) {
            buffer.append(bytes[start..<newline])
            guard buffer.count <= maximumFrameBytes else { throw BridgeLinkError.messageTooLarge }
            guard String(data: buffer, encoding: .utf8) != nil else { throw BridgeLinkError.invalidUTF8 }
            messages.append(try ZeusJSON.decoder().decode(WireMessage.self, from: buffer))
            buffer.removeAll(keepingCapacity: true)
            start = bytes.index(after: newline)
        }
        buffer.append(bytes[start...])
        guard buffer.count <= maximumFrameBytes else { throw BridgeLinkError.messageTooLarge }
        return messages
    }
    /// Validates EOF; unterminated JSON is never silently discarded.
    public func finish() throws {
        guard buffer.isEmpty else { throw BridgeLinkError.truncatedMessage }
    }
    /// Encodes one message with exactly one terminating newline.
    public static func encode(_ message: WireMessage) throws -> Data {
        var data = try ZeusJSON.encoder().encode(message)
        data.append(10)
        return data
    }
}
