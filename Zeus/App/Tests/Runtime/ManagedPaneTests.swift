import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

/// M0's real-agent visible-pane captures; metadata is converted to today's cursor format.
func managedSnapshot(_ name: String) throws -> ManagedPaneSnapshot {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    let raw = try String(contentsOf: root.appendingPathComponent("TestFixtures/panes/\(name).txt"), encoding: .utf8)
    let split = try #require(raw.firstIndex(of: "\n"))
    let fields = raw[..<split].split(separator: "|", omittingEmptySubsequences: false)
    let offset = fields.count == 8 ? 5 : 4
    return .init(screen: String(raw[raw.index(after: split)...]), inputMetadata: "\(fields[offset])|\(fields[offset + 1])|160|\(fields[2])|1")
}

@MainActor
struct ManagedPaneTests {
    @Test(arguments: [
        ("claude-trust", AgentKind.claude), ("claude-after-trust", .claude), ("claude-login-login", .claude),
        ("claude-blocked-permission", .claude), ("permissions/claude-yolo-bypass-warning", .claude),
        ("codex-login-launch", .codex), ("codex-blocked-permission", .codex),
        ("opencode-blocked-permission", .opencode), ("opencode-login-login-prompt", .opencode)
    ])
    func realDialogsWinOverWork(_ sample: (String, AgentKind)) throws {
        let value = ManagedPaneClassifier.classify(try managedSnapshot(sample.0), agent: sample.1)
        guard case .blocked(let reason, let dialog) = value else { Issue.record("\(sample.0): \(value)"); return }
        #expect(!reason.isEmpty && !dialog.isEmpty)
    }
    @Test(arguments: [("claude-working", AgentKind.claude), ("codex-working-confirmed", .codex), ("opencode-working", .opencode)])
    func liveWorkingFooters(_ sample: (String, AgentKind)) throws {
        #expect(ManagedPaneClassifier.classify(try managedSnapshot(sample.0), agent: sample.1) == .working)
    }
    @Test(arguments: [("claude-idle", AgentKind.claude), ("codex-ready", .codex), ("opencode-ready", .opencode), ("opencode-login-missing-auth", .opencode)])
    func oldHistoryAndErrorsAreNotLiveBlocks(_ sample: (String, AgentKind)) throws {
        #expect(ManagedPaneClassifier.classify(try managedSnapshot(sample.0), agent: sample.1) == .idle)
    }
    @Test func graceDebounceManagedOnlyAndDeadPrecedence() async throws {
        let f = try ManagedFixture(); defer { f.cleanup() }
        await f.host.occupy("other")
        f.controller.activate(); try await f.settle()
        let blocked = try managedSnapshot("claude-blocked-permission")
        await f.host.setSnapshot(blocked)
        f.controller.refresh(); try await f.settle()
        #expect(f.controller.managedStatus == .starting)
        f.clock.advance(9, wake: false); f.controller.refresh(); try await f.settle()
        #expect(f.controller.managedStatus == .starting)
        f.clock.advance(1, wake: false); f.controller.refresh(); try await f.settle()
        #expect({ if case .blocked = f.controller.managedStatus { true } else { false } }())
        #expect(!f.controller.canAcceptInput)
        await f.host.setSnapshot(try managedSnapshot("claude-idle")); f.controller.refresh(); try await f.settle()
        #expect(f.controller.managedStatus == .running(.idle) && f.controller.canAcceptInput)
        await f.host.setSnapshot(blocked); f.controller.refresh(); try await f.settle()
        #expect(f.controller.managedStatus == .running(.unknown))
        #expect(!f.controller.canAcceptInput)
        await f.host.setSnapshot(try managedSnapshot("claude-working")); f.controller.refresh(); try await f.settle()
        await f.host.setSnapshot(blocked); f.controller.refresh(); try await f.settle()
        #expect(f.controller.managedStatus == .running(.unknown))
        f.controller.refresh(); try await f.settle()
        #expect({ if case .blocked = f.controller.managedStatus { true } else { false } }())
        let own = try #require(f.controller.record?.pane?.id)
        #expect(await f.host.captures.allSatisfy { $0 == own })
        await f.host.die(status: 0); f.controller.refresh(); try await f.settle()
        #expect(f.controller.managedStatus == .stopped)
    }
    @Test func defaultFolderUsesBundleTemplatesAndNeverOverwrites() throws {
        let f = try ManagedFixture(); defer { f.cleanup() }
        // The test host is Zeus.app; verify its actual copied resources.
        let first = try f.controller.createDefaultFolder()
        let second = try f.controller.createDefaultFolder()
        #expect(first.lastPathComponent == "Zeus Assistant")
        #expect(second.lastPathComponent == "Zeus Assistant 2")
        for name in ["AGENTS.md", "CLAUDE.md"] {
            let resource = try #require(Bundle.main.resourceURL?.appendingPathComponent(name))
            #expect(try Data(contentsOf: first.appendingPathComponent(name)) == Data(contentsOf: resource))
        }
        #expect(try FileManager.default.attributesOfItem(atPath: first.path)[.posixPermissions] as? Int == 0o700)
    }
}

extension ManagedPaneTests {
    @Test(arguments: ["visible", "hidden"])
    func realOpenCodePasteVerification(summary: String) throws {
        struct Snapshot: Decodable { var screen: String; var inputMetadata: String }
        struct Fixture: Decodable { var before: Snapshot; var after: Snapshot; var text: String }
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let data = try Data(contentsOf: root.appendingPathComponent("TestFixtures/panes/m2b/opencode-\(summary)-paste.json"))
        let f = try JSONDecoder().decode(Fixture.self, from: data)
        let before = try #require(TmuxInputSnapshot(metadata: Data(f.before.inputMetadata.utf8), screen: Data(f.before.screen.utf8)))
        let after = try #require(TmuxInputSnapshot(metadata: Data(f.after.inputMetadata.utf8), screen: Data(f.after.screen.utf8)))
        #expect(before.isEmpty)
        #expect(after.containsOnlyPaste(f.text, after: before) == (summary == "visible"))
        #expect(!after.containsOnlyPaste(f.text + "extra human draft", after: before))
        #expect(!after.isEmpty)
        if summary == "visible" {
            // Captured cursor_x is 36; replacing 'with' (four cells) tests actual cell positions.
            for (replacement, cursor) in [("✅", 34), ("e\u{0301}", 33), ("👨‍👩‍👧‍👦", 34)] {
                let screen = f.after.screen.replacingOccurrences(of: "with this", with: replacement + " this")
                let metadata = "\(cursor)|34|160|0|1"
                let unicode = try #require(TmuxInputSnapshot(metadata: Data(metadata.utf8), screen: Data(screen.utf8)))
                #expect(unicode.containsOnlyPaste(f.text.replacingOccurrences(of: "with this", with: replacement + " this"), after: before))
            }
            let draft = try #require(TmuxInputSnapshot(metadata: Data(f.after.inputMetadata.utf8), screen: Data(f.after.screen.replacingOccurrences(of: "[zeus", with: " [zeus").utf8)))
            #expect(!draft.containsOnlyPaste(f.text, after: before))
        }
    }
}

extension ManagedPaneTests {
    @Test func monitorSamplesAtThreeSecondsAndStopsWithController() async throws {
        let f = try ManagedFixture(); defer { f.cleanup() }
        f.controller.activate(); try await f.settle()
        await f.host.setSnapshot(try managedSnapshot("claude-idle"))
        try await eventually { f.clock.pendingDeadlines.contains(f.clock.now.addingTimeInterval(3)) }
        f.clock.advance(2)
        #expect(await f.host.captures.isEmpty)
        f.clock.advance(1)
        try await eventually { !f.controller.isBusy && f.clock.pendingDeadlines.contains(f.clock.now.addingTimeInterval(3)) }
        #expect(await f.host.captures.count == 1)
        f.clock.advance(3)
        try await eventually { !f.controller.isBusy && f.clock.pendingDeadlines.contains(f.clock.now.addingTimeInterval(3)) }
        #expect(await f.host.captures.count == 2)
        f.controller.stopManagedSession(); try await f.settle()
        f.clock.advance(60)
        #expect(await f.host.captures.count == 2)
    }
}

actor ManagedDialogRunner: ProcessRunning {
    let frames: [ManagedPaneSnapshot]
    var index = 0
    var calls: [[String]] = []
    init(frames: [ManagedPaneSnapshot]) { self.frames = frames }
    func run(executable: URL, arguments: [String], input: Data?) -> ProcessResult {
        calls.append(arguments)
        let command = arguments.dropFirst(3).first // -u -S <isolated namespace>
        switch command {
        case "display-message": return .init(status: 0, stdout: Data(frames[index].inputMetadata.utf8))
        case "capture-pane":
            let data = Data(frames[index].screen.utf8)
            index = min(index + 1, frames.count - 1)
            return .init(status: 0, stdout: data)
        default: return .init(status: 0)
        }
    }
}

extension ManagedPaneTests {
    @Test(arguments: [false, true])
    func liveDialogChecksPreventTypingAndEnter(afterPaste: Bool) async throws {
        let idle = try managedSnapshot("claude-idle"), blocked = try managedSnapshot("claude-blocked-permission")
        let runner = ManagedDialogRunner(frames: afterPaste ? [idle, idle, blocked] : [blocked])
        let routing = FakeRouting(); routing.deliveryMethod = .polling; routing.tmuxTarget = "%wrong"
        let context = DeliveryRoutingContext(settings: routing, assistantSessionKey: "managed", tmuxSocketPath: "/tmp/managed-fixture.sock")
        context.managedMethod = .tmux; context.managedPane = "%owned"; context.managedInputAllowed = { true }
        let session = connectorSession(agent: .claude, pane: "%owned")
        let delivery = Delivery(kind: .userMessage, sessionKey: session.sessionKey, content: "Keep this queued")
        await #expect(throws: ConnectorError.inputBusy) {
            try await TmuxConnector(executable: URL(fileURLWithPath: "/test/tmux"), runner: runner).deliver(delivery, to: session, bridge: nil, routing: context)
        }
        let calls = await runner.calls
        #expect(!calls.contains { $0.contains("send-keys") })
        #expect(calls.contains { $0.contains("paste-buffer") } == afterPaste)
        #expect(calls.allSatisfy { Array($0.prefix(3)) == ["-u", "-S", "/tmp/managed-fixture.sock"] })
        #expect(calls.filter { $0.contains("capture-pane") }.allSatisfy { $0.suffix(1) == ["%owned"] })
    }
}
