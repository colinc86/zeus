import Darwin
import Foundation
import Testing
import ZeusProtocol
import ZeusDesign
@testable import Zeus

/// Production settings/model, runtime, bundled MCP bridge, tmux host and delivery connector.
/// Only the agent/model and Terminal opener are fake. Every process uses a private socket and HOME.
@MainActor struct ManagedFlowE2ETests {
    @Test(.timeLimit(.minutes(2)))
    func configuredAssistantBlocksDeliversResumesAndStopsInPrivateTmux() async throws {
        await NativeProcessTestGate.acquire()
        defer { NativeProcessTestGate.release() }
        let tmux = try #require(TmuxExecutable.resolve())
        let python = try #require(["/opt/homebrew/bin/python3", "/usr/bin/python3"].first { FileManager.default.isExecutableFile(atPath: $0) })
        let bridge = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/zeus-mcp")
        try #require(FileManager.default.isExecutableFile(atPath: bridge.path))
        let root = URL(fileURLWithPath: "/tmp/zm4b_" + UUID().uuidString.prefix(8), isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let socket = root.appendingPathComponent("tmux.sock").path
        let suite = TestDefaults.suite("zeus-m4b-flow")
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            let cleanup = Process(); cleanup.executableURL = tmux; cleanup.arguments = ["-S", socket, "kill-server"]
            cleanup.standardOutput = FileHandle.nullDevice; cleanup.standardError = FileHandle.nullDevice
            try? cleanup.run(); cleanup.waitUntilExit()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let source = root.appendingPathComponent("agent.py")
        try Data(Self.agent.utf8).write(to: source)
        let executable = root.appendingPathComponent("claude")
        let script = "#!/bin/sh\nexec " + ManagedSessionController.shellQuote(python) + " " + ManagedSessionController.shellQuote(source.path) + " \"$@\"\n"
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let mode = home.appendingPathComponent("mode")
        try Data("blocked".utf8).write(to: mode)
        let settings = AppSettings(defaults: defaults, userDirectory: nil)
        let clock = TestRuntimeClock()
        let terminal = FakeManagedTerminal()
        let controller = ManagedSessionController(configuration: { settings.managedSession },
            stateURL: root.appendingPathComponent("managed.json"), bridge: bridge, bridgeSocket: root.appendingPathComponent("bridge.sock").path,
            executables: .init(tmux: tmux, agents: [.claude: executable]),
            environment: ["HOME": home.path, "CLAUDE_CONFIG_DIR": home.appendingPathComponent("claude-config").path, "PATH": "/usr/bin:/bin"],
            clock: clock, terminalOpener: terminal, isolatedSocket: socket)
        let cards = CardStore(fileURL: root.appendingPathComponent("cards.json"), clock: { clock.now })
        let avatar = AvatarStatusModel(cards: cards)
        let runtime = ZeusRuntime(cards: cards, status: avatar, characters: settings, routing: settings, clock: clock,
            socketPath: root.appendingPathComponent("bridge.sock").path, ledgerURL: root.appendingPathComponent("deliveries.json"),
            connectors: [TmuxConnector(executable: tmux)], managedController: controller)
        defer { runtime.stop() }
        let managed = ManagedAssistantModel(settings: settings, controller: { runtime })
        managed.createFolder = { [weak runtime] in
            guard let runtime else { throw CancellationError() }
            return try runtime.createDefaultFolder()
        }
        let conversation = ConversationModel(cards: cards, messaging: runtime, clock: { clock.now })
        try runtime.start()
        try await wait("initial off/stopped", controller: controller) { !controller.isBusy }
        managed.refreshAvailability(); managed.createDefaultFolder()
        let folder = try #require(settings.managedSession?.folder)
        #expect(folder == home.appendingPathComponent("Zeus Assistant").path)
        #expect(FileManager.default.fileExists(atPath: folder + "/AGENTS.md"))
        #expect(FileManager.default.fileExists(atPath: folder + "/CLAUDE.md"))
        #expect(AppSettings(defaults: defaults, userDirectory: nil).managedSession == settings.managedSession)
        #expect(cards.cards.isEmpty)
        #expect(managed.canStart && managed.config.startWhenZeusOpens)
        managed.perform(.start)
        // MCP initialize acknowledges stdio, not the asynchronous Zeus hello.
        // Permit the fixture's first tool call only after its exact parent is bound.
        try await wait("exact owned bridge transport", controller: controller) {
            controller.sessionKey != nil && !controller.isBusy
        }
        let readyPID = try #require(controller.record?.pane?.pid)
        try Data(String(readyPID).utf8).write(to: home.appendingPathComponent("allow-ready-call"), options: .atomic)
        try await wait("MCP check-in and exact owned session", controller: controller) {
            controller.sessionKey != nil && cards.cards.first?.body == "Fake assistant ready." && !controller.isBusy && FileManager.default.fileExists(atPath: home.appendingPathComponent("screen-ready").path)
        }
        let first = try #require(controller.record?.pane)
        let nativeID = try #require(controller.record?.conversation?.nativeID)
        try #require(first.socket == URL(fileURLWithPath: socket).resolvingSymlinksInPath().path)
        #expect(runtime.sessions.first?.sessionKey == controller.sessionKey)
        #expect(runtime.managedStatus == .starting)
        #expect(ConversationView.composerPlaceholder(managed: settings.managedSession, status: runtime.managedStatus, assistantLabel: nil) == "Message your assistant…")

        clock.advance(11, wake: false)
        for _ in 0..<2 {
            controller.refresh()
            try await wait("blocked sample", controller: controller) { !controller.isBusy }
        }
        guard case .blocked = runtime.managedStatus else { throw ManagedSessionError.command("Expected blocked, got \(runtime.managedStatus)") }
        let blocked = try #require(cards.cards.first { $0.id.hasPrefix(ZeusRuntime.managedCardPrefix) })
        #expect(blocked.priority == .high && blocked.options.contains { $0.id == "open-terminal" } && avatar.state == .alert)
        let saved = try Data(contentsOf: root.appendingPathComponent("cards.json"))
        #expect(conversation.pickOption(cardID: blocked.id, optionID: "open-terminal"))
        try await wait("local Terminal action", controller: controller) { terminal.files.count == 1 && !controller.isBusy }
        #expect(try Data(contentsOf: root.appendingPathComponent("cards.json")) == saved)
        #expect(cards.card(id: blocked.id)?.status == .open && cards.card(id: blocked.id)?.response == nil)
        #expect(runtime.ledger?.records.isEmpty == true && runtime.responseJournal?.intents.isEmpty == true)
        #expect(try String(contentsOf: terminal.files[0], encoding: .utf8).contains(first.socket))

        // The fake human clears the dialog via its control file. Zeus never types into the dialog.
        try Data("idle".utf8).write(to: mode, options: .atomic)
        try await waitForScreen("idle composer", controller: controller) {
            controller.managedStatus == .running(.idle) && !controller.isBusy
        }
        #expect(cards.card(id: blocked.id)?.status == .answered)
        #expect(cards.card(id: blocked.id)?.body == ZeusManagedCopy.blockedCardResolved)
        #expect(cards.card(id: blocked.id)?.options.isEmpty == true && cards.card(id: blocked.id)?.response == nil)
        conversation.draft = "Hello fake assistant."
        let sent = await conversation.send()
        guard case .message(_, .delivered)? = sent else { Issue.record("Message was not delivered: \(String(describing: sent))"); return }
        try await wait("real paste/Enter receipt and MCP ack", controller: controller) {
            runtime.ledger?.records.first?.delivery.ackedAt != nil && cards.cards.contains { $0.body == "Fake assistant received your message." }
        }
        let inbox = try String(contentsOf: home.appendingPathComponent("inbox.jsonl"), encoding: .utf8)
        #expect(inbox.split(separator: "\n").count == 1 && inbox.contains("Hello fake assistant."))
        #expect(conversation.thread.contains { $0.isUser && $0.body == "Hello fake assistant." })
        #expect(runtime.responseJournal?.intents.isEmpty == true)

        // Kill only the verified child belonging to this private server, then resume its native UUID.
        try #require(controller.record?.pane?.socket == first.socket && first.pid > 1 && first.pid != Int(getpid()))
        try #require(kill(Int32(first.pid), SIGKILL) == 0)
        try await waitForScreen("crash backoff", controller: controller) {
            if case .restarting = runtime.managedStatus { return true }; return false
        }
        clock.advance(2)
        try await wait("native resume and new MCP parent lifetime", controller: controller) {
            controller.record?.pane?.pid != first.pid && controller.sessionKey != nil && !controller.isBusy
        }
        #expect(controller.record?.conversation?.nativeID == nativeID)
        let launches = try String(contentsOf: home.appendingPathComponent("launches.jsonl"), encoding: .utf8).split(separator: "\n")
        #expect(launches.count == 2 && launches[0].contains("Zeus managed conversation"))
        #expect(launches[1].contains("--resume") && launches[1].contains(nativeID) && !launches[1].contains("Zeus managed conversation"))
        #expect(cards.cards.filter { $0.body == "Fake assistant ready." }.count == 1)
        let resumedPID = try #require(controller.record?.pane?.pid)
        managed.perform(.stop)
        try await wait("stop and pane release", controller: controller) {
            runtime.managedStatus == .stopped && controller.managedTmuxSessionName == nil && !controller.isBusy
        }
        #expect(kill(Int32(resumedPID), 0) == -1)
        #expect(cards.persistenceError == nil)
        print("M4b managed E2E passed: configure/create → start/check-in → blocked/local Terminal → resolve → paste/ack → SIGKILL/native resume → stop; private socket only")
    }

    private func wait(_ phase: String, controller: ManagedSessionController, condition: () -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(8)
        while !condition() {
            guard ContinuousClock.now < end else {
                let errors = controller.record?.pane.map { URL(fileURLWithPath: $0.socket).deletingLastPathComponent().appendingPathComponent("home/agent-errors.log") }
                let detail = errors.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "No fixture-agent exception recorded"
                throw ManagedSessionError.command("M4b \(phase): \(controller.managedStatus); \(detail.suffix(2000))")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    private func waitForScreen(_ phase: String, controller: ManagedSessionController, condition: () -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(8)
        while !condition() {
            guard ContinuousClock.now < end else {
                var detail = ""
                if let host = controller.hosting, let pane = controller.record?.pane, let owner = controller.record?.owner,
                   let snapshot = try? await host.capture(pane, owner: owner) {
                    detail = " metadata=\(snapshot.inputMetadata) screen=\(snapshot.screen.prefix(500))"
                }
                throw ManagedSessionError.command("M4b \(phase): \(controller.managedStatus)\(detail)")
            }
            controller.refresh()
            try await wait(phase, controller: controller) { !controller.isBusy }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private static let agent = #"""
import json, os, pathlib, re, select, signal, subprocess, sys, termios, time, traceback, tty
home = pathlib.Path(os.environ['HOME'])
def failure(kind, value, trace):
    with (home/'agent-errors.log').open('a') as log: traceback.print_exception(kind,value,trace,file=log)
    sys.__excepthook__(kind,value,trace)
sys.excepthook = failure
a = sys.argv[1:]
def value(flag): return a[a.index(flag)+1] if flag in a else None
fresh = '--session-id' in a
native = value('--session-id') if fresh else value('--resume')
if fresh: (home/'native').write_text(native)
elif (home/'native').read_text() != native: sys.exit(7)
with (home/'launches.jsonl').open('a') as f: f.write(json.dumps(a)+'\n')
config = json.loads(pathlib.Path(value('--mcp-config')).read_text())['mcpServers']['zeus']
error = (home/'bridge-errors.log').open('a')
bridge = subprocess.Popen([config['command']] + config['args'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=error, text=True, bufsize=1)
seq = 0
def rpc(method, params):
    global seq
    seq += 1
    bridge.stdin.write(json.dumps({'jsonrpc':'2.0','id':seq,'method':method,'params':params})+'\n'); bridge.stdin.flush()
    while True:
        line = bridge.stdout.readline()
        if not line: raise RuntimeError('MCP EOF')
        answer = json.loads(line)
        if answer.get('id') == seq:
            if 'error' in answer or answer.get('result',{}).get('isError'): raise RuntimeError(str(answer))
            return answer['result']
def tool(name, args): return rpc('tools/call', {'name':name,'arguments':args})
rpc('initialize', {'protocolVersion':'2025-06-18','capabilities':{},'clientInfo':{'name':'M4b fake Claude','version':'1'}})
bridge.stdin.write(json.dumps({'jsonrpc':'2.0','method':'notifications/initialized'})+'\n'); bridge.stdin.flush()
if fresh:
    permit = home/'allow-ready-call'
    while not permit.exists() or permit.read_text() != str(os.getpid()): time.sleep(0.01)
    tool('zeus_say', {'text':'Fake assistant ready.'})
fd = sys.stdin.fileno(); old = termios.tcgetattr(fd); tty.setraw(fd)
signal.signal(signal.SIGINT, lambda *_: sys.exit(0))
signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
draft = ''; mode = None; wire = b''
sys.stdout.write('\x1b[?2004h'); sys.stdout.flush()
def redraw():
    if mode == 'blocked':
        screen = 'Bash command\r\n  echo fake\r\nDo you want to proceed?\r\n❯ 1. Yes\r\n  2. No\r\nEsc to cancel · Enter to confirm'
        cursor = '\x1b[6;1H'
    else:
        width = os.get_terminal_size(fd).columns
        full = '❯ '+draft
        rows = [full[i:i+width] for i in range(0,len(full),width)]
        if len(full) % width == 0: rows.append('')
        screen = 'M4b fake Claude\r\n\r\n'+'\r\n'.join('\x1b[48;5;234m'+row+'\x1b[0m' for row in rows)+'\r\n'+'─'*20
        cursor = '\x1b[%d;%dH' % (3+len(rows)-1,len(rows[-1])+1)
    sys.stdout.write('\x1b[2J\x1b[H'+screen+cursor); sys.stdout.flush()
try:
    while True:
        next_mode = (home/'mode').read_text().strip()
        if next_mode != mode:
            mode = next_mode; redraw(); (home/'screen-ready').write_text(mode)
        if not select.select([fd],[],[],0.02)[0]: continue
        data = os.read(fd,4096)
        if not data: break
        if b'\x03' in data: break
        wire += data
        while wire:
            if wire.startswith(b'\x1b'):
                end = wire.find(b'~')
                if end < 0: break
                sequence, wire = wire[:end+1], wire[end+1:]
                if sequence not in (b'\x1b[200~', b'\x1b[201~'): raise RuntimeError('Unexpected terminal input')
                continue
            char, wire = chr(wire[0]), wire[1:]
            if char in '\r\n':
                if mode == 'blocked': raise RuntimeError('Zeus typed into a blocked dialog')
                match = re.search(r'delivery_id=([^\] ]+)',draft)
                if match:
                    with (home/'inbox.jsonl').open('a') as f: f.write(json.dumps({'text':draft,'native':native})+'\n')
                    tool('zeus_ack', {'delivery_ids':[match.group(1)]})
                    tool('zeus_say', {'text':'Fake assistant received your message.'})
                draft = ''
            else: draft += char
        redraw()
finally:
    termios.tcsetattr(fd,termios.TCSANOW,old)
    bridge.stdin.close()
    try: bridge.wait(timeout=2)
    except subprocess.TimeoutExpired: bridge.kill(); bridge.wait()
"""#
}
