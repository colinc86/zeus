import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

extension ZeusE2ETests {
    @Test @MainActor func realOpenCodeBridgesInSameFolderUseDistinctNativeSessionsAndRecoverLostHTTPResult() async throws {
        let http = NativeOpenCodeHTTP()
        let f = try E2EFixture(connectors: [OpenCodeConnector(transport: http, credentials: { nil })]); defer { f.stop() }
        let cwd = f.directory.appendingPathComponent("shared")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        let a = try E2EBridge(socketPath: f.runtime.socketPath, cwd: cwd, agent: .opencode, separateAgentParent: true)
        let b = try E2EBridge(socketPath: f.runtime.socketPath, cwd: cwd, agent: .opencode, separateAgentParent: true)
        f.children += [a, b]; try await a.initialize(); try await b.initialize()
        try await eventually { f.runtime.sessions.count == 2 }
        let askedA = try await a.call("zeus_ask", ["text": "A", "wait_seconds": 0])
        let askedB = try await b.call("zeus_ask", ["text": "B", "wait_seconds": 0])
        let idA = try e2eString(askedA["card_id"]), idB = try e2eString(askedB["card_id"])
        let keyA = try #require(f.cards.card(id: idA)?.sessionKey), keyB = try #require(f.cards.card(id: idB)?.sessionKey)
        #expect(keyA != keyB)
        f.routing.deliveryMethod = .opencode; f.routing.openCodeBaseURL = URL(string: "http://localhost:4096")
        f.routing.openCodeSessionIDs = [keyA: "ses_A", keyB: "ses_B"]
        await http.configure(failAfterSave: true, directory: cwd.path)
        try f.answer(idA, text: "Only A"); try f.answer(idB, text: "Only B")
        try await eventually { f.runtime.sends.isEmpty && f.runtime.ledger?.records.count == 2 }
        let calls = await http.calls.filter { $0.httpMethod == "POST" }
        #expect(Set(calls.compactMap { $0.url?.path }) == ["/session/ses_A/prompt_async", "/session/ses_B/prompt_async"])
        #expect(calls.count == 2 && !calls.contains { $0.url?.path.contains("tui") == true })
        f.runtime.retryPendingDeliveries()
        try await eventually { f.runtime.sends.isEmpty }
        #expect(await http.calls.filter { $0.httpMethod == "POST" }.count == 2)
        #expect(try await a.call("zeus_get_responses")["items"]?[0]?["text"] == "Only A")
        #expect(try await b.call("zeus_get_responses")["items"]?[0]?["text"] == "Only B")
        try await a.finish(); try await b.finish()
    }
}
