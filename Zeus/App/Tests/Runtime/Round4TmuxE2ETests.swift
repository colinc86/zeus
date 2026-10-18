import Foundation
import Darwin
import xlocale
import Testing
import ZeusProtocol
@testable import Zeus

extension ZeusE2ETests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ZEUS_TEST_TMUX"] == "1"),
          arguments: [String(repeating: "A long paragraph with Unicode 🐈 and é. ", count: 40),
                      String(repeating: "中文", count: 180), String(repeating: "é é ", count: 180)])
    func longMessageInShortPaneSubmitsPointerAndFetchesExactBody(content: String) async throws {
        let binary = try #require(TmuxExecutable.resolve())
        let runner = try PrivateTestTmuxRunner()
        defer { runner.stop(executable: binary) }
        let f = try E2EFixture(connectors: [TmuxConnector(executable: binary, runner: runner)])
        defer { f.stop() }
        let created = try await runner.run(executable: binary, arguments: ["new-session", "-d", "-s", "scratch", "-x", "80", "-y", "8", "-P", "-F", "#{pane_id}", "/bin/cat"], input: nil)
        try #require(created.status == 0)
        let pane = String(decoding: created.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let meta = try await runner.run(executable: binary, arguments: ["display-message", "-p", "-t", pane, "#{socket_path},#{pid},0"], input: nil)
        let environment = String(decoding: meta.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        f.routing.deliveryMethod = .tmux; f.routing.tmuxTarget = pane
        f.routing.tmuxTargetSocketPath = environment.split(separator: ",").first.map(String.init)
        let bridge = try await f.bridge("short-pane", agent: .codex, pane: pane, tmuxEnvironment: environment)
        #expect(await f.runtime.sendUserMessage(content) == .delivered)
        let record = try #require(f.runtime.ledger?.records.first)
        #expect(record.delivery.attempts == 1)
        #expect(record.delivery.meta["tmux_pointer"] == "true")
        #expect(record.delivery.ackedAt == nil)
        let capture = try await runner.run(executable: binary, arguments: ["capture-pane", "-p", "-t", pane], input: nil)
        let screen = String(decoding: capture.stdout, as: UTF8.self)
        #expect(screen.contains("zeus_get_responses"))
        #expect(!screen.contains(content))
        let poll = try await bridge.call("zeus_get_responses", ["id": .string(record.delivery.id)])
        #expect(poll["items"]?[0]?["delivery_id"] == .string(record.delivery.id))
        #expect(poll["items"]?[0]?["text"] == .string(record.delivery.content))
        #expect(f.runtime.ledger?.records.first?.delivery.ackedAt != nil)
        try await bridge.finish()
    }
}

struct PasteCapacityTests {
    @Test func cellWidthsAreUTF8AndLeaveTheCallingLocaleUnchanged() {
        let previous = uselocale(nil)
        #expect(TmuxInputSnapshot.cellWidth("中文") == 4)
        #expect(TmuxInputSnapshot.cellWidth("é é") == 3)
        #expect(TmuxInputSnapshot.cellWidth("👨‍👩‍👧‍👦") == 2)
        #expect(TmuxInputSnapshot.cellWidth("ＡＢ") == 4)
        #expect(TmuxInputSnapshot.cellWidth("\u{0301}") == 0)
        #expect(uselocale(nil) == previous)
    }
    @Test func wrappedWideCharactersUseCellsAndStillRejectExtraInput() throws {
        let before = try #require(TmuxInputSnapshot(metadata: Data("0|0|5|0|1".utf8), screen: Data("\n\n".utf8)))
        let after = try #require(TmuxInputSnapshot(metadata: Data("4|1|5|0|1".utf8), screen: Data("中中\n文éx\n".utf8)))
        #expect(after.containsOnlyPaste("中中文éx", after: before))
        #expect(!after.containsOnlyPaste("中中文é", after: before))
    }
    @Test func unicodeLongEnvelopeCannotScrollOutOfVisibleSnapshot() throws {
        let before = try #require(TmuxInputSnapshot(metadata: Data("0|0|80|0|1".utf8), screen: Data(String(repeating: "\n", count: 7).utf8)))
        #expect(before.canVerifyPaste("Short control"))
        #expect(!before.canVerifyPaste(String(repeating: "🐈 é ", count: 200)))
        let bottom = try #require(TmuxInputSnapshot(metadata: Data("0|7|80|0|1".utf8), screen: Data(String(repeating: "\n", count: 7).utf8)))
        #expect(!bottom.canVerifyPaste(String(repeating: "x", count: 80)))
    }
}
