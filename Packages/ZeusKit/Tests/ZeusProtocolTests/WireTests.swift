import Foundation
import Testing
@testable import ZeusProtocol

@Test func everyWireMessageRoundTripsFlat() throws {
    let hello = BridgeHello(agent: .claude, pid: 123, ppid: 12, cwd: "/work", client: .init(name: "Claude", version: "1"), capabilities: .init(channel: true), tmuxPane: "%7")
    let result = try ToolResult(structured: ["card_id": "c_12345678"])
    let messages: [WireMessage] = [
        .hello(hello), .welcome(.init(sessionKey: hello.sessionKey, appVersion: "1")),
        .toolCall(.init(callID: "call1", name: "zeus_say", arguments: ["text": "Hi"])),
        .toolResult(.init(callID: "call1", result: result)),
        .push(.init(deliveryID: "d_12345678", content: "Hello", meta: ["kind": "userMessage"])),
        .pushWritten(.init(deliveryID: "d_12345678")), .toolResultWritten(.init(callID: "call1")), .error(.init(message: "Bad version")), .superseded(.init(sessionKey: hello.sessionKey))
    ]
    for message in messages {
        let data = try ZeusJSON.encoder().encode(message)
        #expect(try ZeusJSON.decoder().decode(WireMessage.self, from: data) == message)
        let json = try JSONValue.from(message)
        #expect(json["type"] != nil)
        #expect(json["_0"] == nil)
        #expect(json["hello"] == nil)
    }
    #expect(try JSONValue.from(messages[0])["bridgeID"] == .string(hello.bridgeID.uuidString))
    #expect(try JSONValue.from(messages[2])["callID"] == "call1")
    #expect(try JSONValue.from(messages[3])["text"] == .string(result.text))
    #expect(BridgeToolResult(callID: "call1", result: result).result == result)
    #expect(hello.sessionKey == "claude:/work#12.0")
    #expect(BridgeHello(agent: .codex, pid: 1, ppid: 0, cwd: "/work", client: hello.client, capabilities: .init()).sessionKey == "codex:/work#0.0")
    let unknown = Data(#"{"type":"future"}"#.utf8)
    #expect(throws: (any Error).self) { try ZeusJSON.decoder().decode(WireMessage.self, from: unknown) }
}

@Test func standaloneWirePayloadsRoundTrip() throws {
    func check<T: Codable & Equatable>(_ value: T) throws {
        #expect(try ZeusJSON.decoder().decode(T.self, from: ZeusJSON.encoder().encode(value)) == value)
    }
    let client = BridgeHello.Client(name: "Test", version: "1")
    let capabilities = BridgeHello.Capabilities(channel: false)
    try check(client); try check(capabilities)
    try check(BridgeHello(agent: .other, pid: 1, ppid: 0, cwd: "/", client: client, capabilities: capabilities))
    try check(BridgeWelcome(sessionKey: "other:/", appVersion: "1"))
    try check(ToolCall(name: "zeus_list_characters"))
    try check(ToolResult(text: "Error", isError: true))
    try check(BridgeToolResult(callID: "test", text: "Error", isError: true))
    try check(AgentPush(deliveryID: "d_12345678", content: "Hello"))
    try check(PushWritten(deliveryID: "d_12345678"))
    try check(BridgeError(message: "Error"))
}

@Test func agentProcessIdentityIgnoresBridgeAndTerminalPaneAndSeparatesPIDReuse() throws {
    var a = BridgeHello(agent: .claude, pid: 111, ppid: 12, cwd: "/work", client: .init(name: "Test", version: "1"),
                        capabilities: .init(), tmuxPane: "%1", parentStartTime: 123456789)
    var b = a; b.pid = 222; b.bridgeID = UUID(); b.tmuxPane = "%2"
    #expect(a.sessionKey == "claude:/work#12.123456789" && a.sessionKey == b.sessionKey)
    b.ppid = 13; #expect(a.sessionKey != b.sessionKey)
    b.ppid = 12; b.parentStartTime += 1; #expect(a.sessionKey != b.sessionKey)
    guard case .object(var encoded) = try JSONValue.from(a) else { Issue.record("Expected object"); return }
    encoded.removeValue(forKey: "parentStartTime")
    a = try ZeusJSON.decoder().decode(BridgeHello.self, from: ZeusJSON.encoder().encode(JSONValue.object(encoded)))
    #expect(a.parentStartTime == 0) // Server reports upgrade guidance rather than accepting this identity.
}

@Test func mcpDefinitionsMatchContract() throws {
    let expected: [(String, Set<String>, Set<String>)] = [
        ("zeus_say", ["text", "title", "mood", "attachments", "priority", "ttl_seconds"], ["text"]),
        ("zeus_ask", ["text", "title", "options", "allow_text", "placeholder", "multiline", "priority", "wait_seconds"], ["text"]),
        ("zeus_present", ["title", "body", "attachments", "actions", "allow_text", "mood", "priority"], ["title", "body"]),
        ("zeus_update_card", ["card_id", "title", "text", "append_text", "progress"], ["card_id"]),
        ("zeus_dismiss", ["card_id"], ["card_id"]),
        ("zeus_set_status", ["state", "detail", "progress", "ttl_seconds"], ["state"]),
        ("zeus_get_responses", [], []), ("zeus_ack", ["delivery_ids"], ["delivery_ids"]),
        ("zeus_list_characters", [], []), ("zeus_set_character", ["id"], ["id"])
    ]
    #expect(ZeusMCP.tools.count == expected.count)
    for (name, keys, required) in expected {
        let tool = try #require(ZeusMCP.tools.first { $0.name == name })
        #expect(try ZeusJSON.decoder().decode(MCPToolDefinition.self, from: ZeusJSON.encoder().encode(tool)) == tool)
        guard case .object(let properties) = tool.inputSchema["properties"], case .array(let requirements) = tool.inputSchema["required"] else {
            Issue.record("Missing properties/required for \(name)"); continue
        }
        #expect(Set(properties.keys) == keys)
        #expect(Set(requirements.compactMap { if case .string(let value) = $0 { return value }; return nil }) == required)
        #expect(tool.inputSchema["additionalProperties"] == false)
        #expect(!tool.description.isEmpty)
    }
    #expect(ZeusMCP.protocolVersion == "2025-06-18")
    #expect(ZeusMCP.capabilities(agent: .claude)["experimental"]?["claude/channel"] == [:])
    #expect(ZeusMCP.capabilities(agent: .codex)["experimental"] == nil)
    #expect(ZeusMCP.instructions.contains("delivery_id"))
    #expect(ZeusMCP.instructions.contains("just ack it again"))
    #expect(ZeusMCP.instructions.contains("finish without posting to Zeus"))
    #expect(ZeusMCP.tools.first { $0.name == "zeus_set_status" }?.description.contains("state \"auto\" to clear the activity indicator") == true)
    #expect(ZeusMCP.tools.first { $0.name == "zeus_ask" }?.inputSchema["properties"]?["wait_seconds"]?["default"] == 45)
    #expect(ZeusMCP.tools.first { $0.name == "zeus_set_status" }?.inputSchema["properties"]?["ttl_seconds"]?["default"] == 600)
}

@Test func resultReceiptNegotiationDefaultsOffForLegacyPeers() throws {
    let caps = try ZeusJSON.decoder().decode(BridgeHello.Capabilities.self, from: Data(#"{"channel":true}"#.utf8))
    #expect(caps.channel && !caps.toolResultWritten)
    let welcome = try ZeusJSON.decoder().decode(BridgeWelcome.self, from: Data(#"{"wireVersion":1,"sessionKey":"claude:/x","appVersion":"1"}"#.utf8))
    #expect(!welcome.toolResultWritten)
    let capable = BridgeWelcome(sessionKey: "s", appVersion: "1", toolResultWritten: true)
    #expect(try ZeusJSON.decoder().decode(BridgeWelcome.self, from: ZeusJSON.encoder().encode(capable)) == capable)
}

@Test func pollingInstructionsExplainBoundedBatches() {
    #expect(ZeusMCP.instructions.contains("keep polling until items is empty"))
    #expect(ZeusMCP.tools.first { $0.name == "zeus_get_responses" }?.description.contains("bounded batch") == true)
}
