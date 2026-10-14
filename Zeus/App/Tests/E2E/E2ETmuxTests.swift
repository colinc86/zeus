import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

/// Dedicated tmux server; no commands or panes in the user's tmux server are touched.
struct E2ETmuxRunner: ProcessRunning {
    let name = "zeus-p7-" + UUID().uuidString.prefix(8)
    func run(executable: URL, arguments: [String], input: Data?) async throws -> ProcessResult {
        try await FoundationProcessRunner().run(executable: executable, arguments: ["-L", name, "-f", "/dev/null"] + arguments, input: input)
    }
}

extension ZeusE2ETests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ZEUS_TEST_TMUX"] == "1"))
    func realTmuxRoutesAutoAssistantAndOriginReplyIntoSeparatePanes() async throws {
        let binary = try #require(TmuxExecutable.resolve(), "ZEUS_TEST_TMUX=1 requires tmux")
        let runner = E2ETmuxRunner()
        let f = try E2EFixture(connectors: [ChannelDeliveryConnector(), TmuxConnector(executable: binary, runner: runner)])
        defer { f.stop() }
        do {
            func pane(_ arguments: [String]) async throws -> String {
                let result = try await runner.run(executable: binary, arguments: arguments, input: nil)
                try #require(result.status == 0)
                let id = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                try #require(id.hasPrefix("%"))
                return id
            }
            let assistantPane = try await pane(["new-session", "-d", "-s", "scratch", "-x", "300", "-y", "30", "-P", "-F", "#{pane_id}", "/bin/cat"])
            let originPane = try await pane(["split-window", "-d", "-t", "scratch", "-P", "-F", "#{pane_id}", "/bin/cat"])
            let metadata = try await runner.run(executable: binary,
                arguments: ["display-message", "-p", "-t", assistantPane, "#{socket_path},#{pid},0"], input: nil)
            try #require(metadata.status == 0)
            let tmuxEnvironment = String(decoding: metadata.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            try #require(tmuxEnvironment.split(separator: ",").count == 3)
            f.routing.tmuxTargetSocketPath = tmuxEnvironment.split(separator: ",").first.map(String.init)
            f.routing.deliveryMethod = .tmux; f.routing.tmuxTarget = assistantPane; f.routing.preferredAgent = .codex
            let origin = try await f.bridge("origin", agent: .codex, pane: originPane, tmuxEnvironment: tmuxEnvironment)
            let assistant = try await f.bridge("assistant", agent: .codex, pane: assistantPane, tmuxEnvironment: tmuxEnvironment)
            #expect(f.runtime.assistantTarget == f.key(agent: .codex, pane: assistantPane))
            let asked = try await origin.call("zeus_ask", ["text": "Origin question", "wait_seconds": 0])
            let cardID = try e2eString(asked["card_id"])
            try f.answer(cardID, text: "Origin-only reply")
            try await eventually { f.runtime.sends.isEmpty && f.runtime.ledger?.records.first?.delivery.attempts == 1 }
            let delivery = try #require(f.runtime.ledger?.records.first?.delivery)
            var captured = ""
            let deadline = ContinuousClock.now + .seconds(2)
            repeat {
                let result = try await runner.run(executable: binary, arguments: ["capture-pane", "-p", "-J", "-t", originPane], input: nil)
                captured = String(decoding: result.stdout, as: UTF8.self)
                if captured.contains(AgentInjectionText.format(delivery)) { break }
                try await Task.sleep(for: .milliseconds(10))
            } while ContinuousClock.now < deadline
            #expect(captured.contains(AgentInjectionText.format(delivery)))
            let assistantCapture = try await runner.run(executable: binary, arguments: ["capture-pane", "-p", "-J", "-t", assistantPane], input: nil)
            #expect(!String(decoding: assistantCapture.stdout, as: UTF8.self).contains("Origin-only reply"))
            let polled = try await origin.call("zeus_get_responses")
            #expect(polled["items"]?[0]?["delivery_id"] == .string(delivery.id))
            #expect(await f.runtime.sendUserMessage("Auto assistant message") == .delivered)
            let message = try #require(f.runtime.ledger?.records.last?.delivery)
            let finalCapture = try await runner.run(executable: binary, arguments: ["capture-pane", "-p", "-J", "-t", assistantPane], input: nil)
            #expect(String(decoding: finalCapture.stdout, as: UTF8.self).contains(AgentInjectionText.format(message)))
            _ = try await assistant.call("zeus_get_responses")
            #expect(origin.channels.isEmpty && assistant.channels.isEmpty)
            let buffers = try await runner.run(executable: binary, arguments: ["list-buffers", "-F", "#{buffer_name}"], input: nil)
            #expect(!String(decoding: buffers.stdout, as: UTF8.self).contains("zeus-d_"))
            try await origin.finish(); try await assistant.finish()
            _ = try await runner.run(executable: binary, arguments: ["kill-server"], input: nil)
        } catch {
            _ = try? await runner.run(executable: binary, arguments: ["kill-server"], input: nil)
            throw error
        }
    }
}


extension ZeusE2ETests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ZEUS_TEST_TMUX"] == "1"))
    func duplicatePaneIDsAcrossServersQueueMismatchedSelectionWithoutTyping() async throws {
        let binary = try #require(TmuxExecutable.resolve())
        let a = E2ETmuxRunner(), b = E2ETmuxRunner()
        let f = try E2EFixture(connectors: [TmuxConnector(executable: binary)])
        defer { f.stop() }
        do {
            func create(_ runner: E2ETmuxRunner) async throws -> (pane: String, env: String, socket: String) {
                let result = try await runner.run(executable: binary, arguments: ["new-session", "-d", "-s", "scratch", "-x", "300", "-y", "30", "-P", "-F", "#{pane_id}", "/bin/sh", "-c", "printf '\\033c'; exec /bin/cat"], input: nil)
                try #require(result.status == 0)
                let pane = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                let metadata = try await runner.run(executable: binary, arguments: ["display-message", "-p", "-t", pane, "#{socket_path},#{pid},0"], input: nil)
                try #require(metadata.status == 0)
                let env = String(decoding: metadata.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                return (pane, env, try #require(env.split(separator: ",").first.map(String.init)))
            }
            let first = try await create(a), second = try await create(b)
            #expect(first.pane == second.pane && first.socket != second.socket)
            let origin = try await f.bridge("origin", agent: .codex, pane: first.pane, tmuxEnvironment: first.env)
            let assistant = try await f.bridge("assistant", agent: .codex, pane: second.pane, tmuxEnvironment: second.env)
            f.routing.deliveryMethod = .tmux; f.routing.preferredAgent = .codex
            f.routing.tmuxTarget = first.pane; f.routing.tmuxTargetSocketPath = first.socket
            let result = await f.runtime.sendUserMessage("Namespace regression message", deliveryID: "d_namespace")
            if case .queued = result {} else { Issue.record("Mismatched namespace must queue") }
            try await eventually { f.runtime.sends.isEmpty }
            #expect(f.runtime.ledger?.record(id: "d_namespace")?.delivery.attempts == 0)
            for runner in [a,b] {
                let capture = try await runner.run(executable: binary, arguments: ["capture-pane", "-p", "-J", "-t", first.pane], input: nil)
                #expect(!String(decoding: capture.stdout, as: UTF8.self).contains("Namespace regression message"))
            }
            // Binding the pane to its actual namespace unlocks the same saved delivery ID.
            f.routing.tmuxTargetSocketPath = second.socket
            f.clock.advance(5); f.runtime.processDueDeliveries()
            try await eventually { f.runtime.sends.isEmpty && f.runtime.ledger?.record(id: "d_namespace")?.transportDeliveredAt != nil }
            let delivered = try #require(f.runtime.ledger?.record(id: "d_namespace")?.delivery)
            let capture = try await b.run(executable: binary, arguments: ["capture-pane", "-p", "-J", "-t", second.pane], input: nil)
            #expect(String(decoding: capture.stdout, as: UTF8.self).contains(AgentInjectionText.format(delivered)))
            let wrong = try await a.run(executable: binary, arguments: ["capture-pane", "-p", "-J", "-t", first.pane], input: nil)
            #expect(!String(decoding: wrong.stdout, as: UTF8.self).contains("Namespace regression message"))
            try await origin.finish(); try await assistant.finish()
            for runner in [a,b] { _ = try await runner.run(executable: binary, arguments: ["kill-server"], input: nil) }
        } catch {
            for runner in [a,b] { _ = try? await runner.run(executable: binary, arguments: ["kill-server"], input: nil) }
            throw error
        }
    }
}
