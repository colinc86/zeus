import Foundation
import ZeusProtocol

internal enum RPCID: Hashable, Sendable {
    case string(String), number(Double)
    init?(_ json: JSONValue) {
        switch json {
        case .string(let value): self = .string(value)
        case .number(let value) where value.isFinite && value.rounded() == value: self = .number(value)
        default: return nil
        }
    }
    var json: JSONValue { switch self { case .string(let value): .string(value); case .number(let value): .number(value) } }
}

// MCP 2025-06-18 uses individual newline-delimited JSON-RPC messages, not batches:
// https://modelcontextprotocol.io/specification/2025-06-18/basic/transports
internal enum JSONRPC {
    static func result(id: RPCID, _ result: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": id.json, "result": result]
    }
    static func error(id: RPCID? = nil, code: Int, message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id?.json ?? .null, "error": ["code": .number(Double(code)), "message": .string(message)]]
    }
    static func toolResult(_ result: ToolResult) -> JSONValue {
        var json: [String: JSONValue] = ["content": [["type": "text", "text": .string(result.text)]], "isError": .bool(result.isError)]
        if let structured = result.structured { json["structuredContent"] = structured }
        return .object(json)
    }
    static func channel(_ push: AgentPush) -> JSONValue {
        let meta = push.meta.filter { key, _ in
            !key.isEmpty && key.utf8.allSatisfy { byte in
                (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 95
            }
        }.mapValues(JSONValue.string)
        return ["jsonrpc": "2.0", "method": "notifications/claude/channel",
                "params": ["content": .string(push.content), "meta": .object(meta)]]
    }
    static func learning(_ learning: BridgeLearning) -> JSONValue {
        ["jsonrpc": "2.0", "method": "notifications/zeus/learning",
         "params": ["id": .string(learning.id), "kind": .string(learning.kind.rawValue), "text": .string(learning.text)]]
    }
}

/// Incremental stdin framing. Oversized lines are discarded through their newline,
/// allowing a subsequent well-formed request to recover without an unbounded buffer.
internal struct StdioFramer {
    enum Frame { case data(Data), oversized }
    let limit: Int
    var buffer = Data()
    var discarding = false

    mutating func append(_ data: Data) -> [Frame] {
        var frames: [Frame] = []
        var start = data.startIndex
        while let newline = data[start...].firstIndex(of: 10) {
            appendPiece(data[start..<newline])
            frames.append(discarding ? .oversized : .data(buffer))
            buffer.removeAll(keepingCapacity: true)
            discarding = false
            start = data.index(after: newline)
        }
        appendPiece(data[start...])
        return frames
    }
    private mutating func appendPiece(_ piece: Data.SubSequence) {
        guard !discarding else { return }
        guard piece.count <= limit - buffer.count else { buffer.removeAll(keepingCapacity: true); discarding = true; return }
        buffer.append(piece)
    }
    var hasIncompleteFrame: Bool { discarding || !buffer.isEmpty }
}
