import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

extension ZeusE2ETests {
    @Test @MainActor func bundledHelperReportsItsAppVersionAndRuntimeErrorsThroughMCP() async throws {
        let f = try E2EFixture(); defer { f.stop() }
        let bridge = try E2EBridge(socketPath: f.runtime.socketPath, cwd: f.directory)
        f.children.append(bridge)
        let initialized = try await bridge.rpc("initialize", ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "Version regression", "version": "1"]])
        let expected = try #require(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        #expect(initialized["serverInfo"]?["version"] == .string(expected))
        let failure = try await bridge.rpc("tools/call", ["name": "zeus_update_card", "arguments": ["card_id": "c_missing"]])
        #expect(failure["isError"] == true && failure["structuredContent"]?["error"] != nil)
        try await bridge.finish()
    }
}
