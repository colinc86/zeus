import Darwin
import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

/// Real tmux and real processes, fake CLIs: no inference, human configuration or default server.
@MainActor
struct ManagedTmuxIntegrationTests {
    @Test(arguments: [AgentKind.claude, .codex, .opencode])
    func ownedLifecycleResumeAndCollisionUseOnlyPrivateSocket(agent: AgentKind) async throws {
        await NativeProcessTestGate.acquire()
        defer { NativeProcessTestGate.release() }
        guard let tmux = TmuxExecutable.resolve() else { return }
        let python = ["/opt/homebrew/bin/python3", "/usr/bin/python3"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let python else { Issue.record("Python is required for the isolated fake-agent fixture"); return }
        let root = URL(fileURLWithPath: "/tmp/zmanaged_" + UUID().uuidString.prefix(8))
        let home = root.appendingPathComponent("home")
        let folder = home.appendingPathComponent("folder with spaces")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        // Force the old log-before-native-context gap on every full-suite run.
        let startupGate = home.appendingPathComponent("hold-native-init")
        try Data().write(to: startupGate)
        let socket = root.appendingPathComponent("tmux.sock").path
        let runner = ManagedFixtureProcessTrace()
        defer {
            let cleanup = Process(); cleanup.executableURL = tmux; cleanup.arguments = ["-S", socket, "kill-server"]
            cleanup.standardOutput = FileHandle.nullDevice; cleanup.standardError = FileHandle.nullDevice
            do {
                try cleanup.run(); cleanup.waitUntilExit()
                #expect(cleanup.terminationStatus == 0, "Private tmux teardown failed; retain the fixture path for cleanup")
                if cleanup.terminationStatus == 0 { try? FileManager.default.removeItem(at: root) }
            } catch { Issue.record("Private tmux teardown: \(error)") }
        }
        let fixture = root.appendingPathComponent("agent.py")
        try Data(Self.agentFixture.utf8).write(to: fixture)
        let executable = root.appendingPathComponent(agent.rawValue)
        let script = "#!/bin/sh\nexec " + ManagedSessionController.shellQuote(python) + " " + ManagedSessionController.shellQuote(fixture.path) + " " + ManagedSessionController.shellQuote(agent.rawValue) + " \"$@\"\n"
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let env = ["HOME": home.path, "PATH": "/usr/bin:/bin", "TMUX": "/unrelated/server,99,0", "TMUX_PANE": "%99", "CODEX_HOME": home.appendingPathComponent("custom-codex").path, "XDG_DATA_HOME": home.appendingPathComponent("custom-data").path]
        // The private server must also die if the test host crashes or is killed,
        // when Swift defer cannot run. This pane belongs exclusively to the fixture.
        let watchdog = root.appendingPathComponent("watchdog.py")
        try Data(Self.watchdogScript.utf8).write(to: watchdog)
        // Simulate a user's unrelated zeus session in this private namespace.
        let occupied = try await runner.run(executable: tmux, arguments: ["-S", socket, "-f", "/dev/null", "new-session", "-d", "-s", "zeus", python, watchdog.path, String(ProcessInfo.processInfo.processIdentifier), tmux.path, socket], input: nil, environment: env)
        #expect(occupied.status == 0)
        var guiEnv = env; guiEnv.removeValue(forKey: "CODEX_HOME"); guiEnv.removeValue(forKey: "XDG_DATA_HOME")
        let config = ManagedConfigBox(); config.value = .init(enabled: true, folder: folder.path, agent: agent, launchPrompt: "Instructions\nwith quotes ' \" and $()", startWhenZeusOpens: true)
        let clock = TestRuntimeClock()
        let controller = ManagedSessionController(configuration: { config.value }, stateURL: root.appendingPathComponent("state.json"), bridge: URL(fileURLWithPath: "/bin/cat"), bridgeSocket: root.appendingPathComponent("bridge.sock").path,
            executables: .init(tmux: tmux, agents: [agent: executable]), hosting: ManagedTmux(executable: tmux, runner: runner, environment: guiEnv, testSocket: socket), environment: guiEnv, clock: clock, isolatedSocket: socket)
        defer { controller.shutdown() }
        controller.activate()
        try await Self.wait("startup lease", controller: controller, home: home) { controller.managedStatus == .starting && !controller.isBusy }
        try await Self.wait("native initialization paused", controller: controller, home: home) { FileManager.default.fileExists(atPath: home.appendingPathComponent("init-paused").path) }
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent("launches.jsonl").path))
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("native.txt").path))
        #expect(Self.fixtureReady(home: home) == nil)
        try FileManager.default.removeItem(at: startupGate)
        try await Self.waitForFixtureReady(controller, home: home, phase: "initial native readiness")
        let identityDeadline = ContinuousClock.now + .seconds(10)
        while controller.record?.conversation?.nativeID == nil {
            guard ContinuousClock.now < identityDeadline else { throw ManagedSessionError.command("Native ID: \(controller.managedStatus); pane: \(String(describing: controller.record?.pane))") }
            clock.advance(3); controller.refresh()
            try await Task.sleep(for: .milliseconds(100))
        }
        try await Self.wait("native discovery completed", controller: controller, home: home) { !controller.isBusy }
        #expect(controller.managedTmuxSessionName == "zeus-2")
        let first = try #require(controller.record?.pane)
        #expect(first.pid > 0 && first.startTime > 0)
        #expect(first.socket == URL(fileURLWithPath: socket).resolvingSymlinksInPath().path || first.socket == socket)
        let reportedKey = "\(agent.rawValue):\(folder.resolvingSymlinksInPath().path)#\(first.pid).\(first.startTime)"
        controller.considerSessions([.init(id: UUID(), sessionKey: reportedKey, agent: agent, cwd: folder.path, clientName: "Fixture", supportsChannel: false, tmuxPane: first.id, connectedAt: clock.now, tmuxSocketPath: first.socket)])
        #expect(controller.sessionKey?.hasSuffix("#\(first.pid).\(first.startTime)") == true)
        #expect(controller.record?.nativeEnvironment["CODEX_HOME"] == env["CODEX_HOME"])
        #expect(controller.record?.nativeEnvironment["XDG_DATA_HOME"] == env["XDG_DATA_HOME"])
        let native = controller.record?.conversation?.nativeID
        // Session option commands silently ignore =name in tmux 3.6a. Resolve
        // immutable IDs and distinguish a missing marker from a foreign marker.
        let inspectionHost = ManagedTmux(executable: tmux, runner: runner, environment: guiEnv, testSocket: socket)
        let inspectionOwner = try #require(controller.record?.owner)
        let sessionTarget = "$" + first.sessionNumber
        runner.beginRestart()
        #expect(try await inspectionHost.inspect(name: first.name, owner: inspectionOwner, pane: first) != nil)
        #expect(runner.ownerRepairs == 0)
        runner.endRestart()
        _ = try await runner.run(executable: tmux, arguments: ["-S", socket, "set-option", "-t", sessionTarget, "@zeus-owner", "foreign-fixture"], input: nil)
        do {
            _ = try await inspectionHost.inspect(name: first.name, owner: inspectionOwner, pane: first)
            Issue.record("A foreign marker must win over the original recovery environment")
        } catch ManagedSessionError.ownershipChanged { }
        _ = try await runner.run(executable: tmux, arguments: ["-S", socket, "set-option", "-u", "-t", sessionTarget, "@zeus-owner"], input: nil)
        #expect(try await inspectionHost.inspect(name: first.name, owner: inspectionOwner, pane: first) != nil)
        let repairedOwner = try await runner.run(executable: tmux, arguments: ["-S", socket, "show-options", "-qv", "-t", sessionTarget, "@zeus-owner"], input: nil)
        #expect(String(decoding: repairedOwner.stdout, as: UTF8.self).trimmingCharacters(in: .newlines) == inspectionOwner)
        let status = try await runner.run(executable: tmux, arguments: ["-S", socket, "show-options", "-wv", "-t", first.id, "remain-on-exit"], input: nil)
        #expect(String(decoding: status.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "on")
        let log = home.appendingPathComponent("launches.jsonl")
        try await Self.wait("launch log", controller: controller, home: home) { FileManager.default.fileExists(atPath: log.path) }
        #expect(try String(contentsOf: log, encoding: .utf8).contains("Zeus managed conversation"))
        // Kill only the verified child in our isolated pane, then resume the exact native context.
        #expect(kill(Int32(first.pid), SIGKILL) == 0)
        controller.refresh()
        try await Self.wait("crash observed", controller: controller, home: home) { if case .restarting = controller.managedStatus { return true }; return false }
        clock.advance(2)
        try await Self.wait("crash recovery lease", controller: controller, home: home) { controller.managedStatus == .starting && controller.record?.pane?.pid != first.pid && !controller.isBusy }
        try await Self.waitForFixtureReady(controller, home: home, phase: "resumed native readiness")
        #expect(controller.record?.conversation?.nativeID == native)
        let rows = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        #expect(rows.count == 2)
        #expect(!rows[1].contains("Zeus managed conversation"))
        #expect(rows[1].contains(native ?? "missing"))
        let alive = try #require(controller.record?.pane)
        controller.shutdown()
        #expect(kill(Int32(alive.pid), 0) == 0)
        config.value?.startWhenZeusOpens = false
        let adopted = ManagedSessionController(configuration: { config.value }, stateURL: root.appendingPathComponent("state.json"), bridge: URL(fileURLWithPath: "/bin/cat"), bridgeSocket: "unused", executables: controller.executables,
            hosting: ManagedTmux(executable: tmux, runner: runner, environment: guiEnv, testSocket: socket), environment: guiEnv, clock: clock, isolatedSocket: socket)
        defer { adopted.shutdown() }
        adopted.activate(); try await Self.wait("adoption", controller: adopted, home: home) { adopted.managedStatus == .starting && !adopted.isBusy }
        #expect(adopted.record?.pane?.pid == alive.pid)
        // A human's split pane shares the owned window, but never Zeus's process lease.
        let split = try await runner.run(executable: tmux, arguments: ["-S", socket, "split-window", "-d", "-P", "-F", "#{pane_id} #{pane_pid}", "-t", alive.id, "/bin/sleep", "86400"], input: nil, environment: env)
        #expect(split.status == 0)
        let human = String(decoding: split.stdout, as: UTF8.self).split(whereSeparator: \.isWhitespace)
        let humanID = String(try #require(human.first))
        let pidText = try #require(human.last)
        let humanPID = try #require(Int32(pidText))
        adopted.stopManagedSession(); try await Self.wait("stop", controller: adopted, home: home) { adopted.managedStatus == .stopped && !adopted.isBusy }
        #expect(kill(humanPID, 0) == 0)
        #expect(adopted.record?.pane == nil)
        let host = ManagedTmux(executable: tmux, environment: env, testSocket: socket)
        let owner = try #require(adopted.record?.owner)
        #expect(try await host.inspect(name: alive.name, owner: owner, pane: nil) == nil)
        // Start, Restart, and New conversation must each leave that human process untouched.
        adopted.startManagedSession(); try await Self.wait("start after stop", controller: adopted, home: home) { adopted.managedStatus == .starting && !adopted.isBusy }
        try await Self.waitForFixtureReady(adopted, home: home, phase: "action native readiness")
        #expect(adopted.record?.pane?.id != humanID)
        #expect(adopted.record?.pane?.name == alive.name)
        let restartedPane = try #require(adopted.record?.pane)
        #expect(adopted.managedAttachCommand?.hasSuffix("attach -t " + ManagedSessionController.shellQuote(restartedPane.id)) == true)
        runner.beginRestart()
        adopted.restartManagedSession()
        do {
            try await Self.wait("restart", controller: adopted, home: home) { adopted.managedStatus == .starting && !adopted.isBusy }
        } catch { throw ManagedSessionError.command("\(error); subprocess trace: \(runner.summary)") }
        print("FX3 restart \(agent): \(runner.summary)")
        #expect(runner.ownerRepairs == 0, "A valid session marker must not enter interrupted-launch recovery")
        runner.endRestart()
        try await Self.waitForFixtureReady(adopted, home: home, phase: "action native readiness")
        #expect(kill(humanPID, 0) == 0)
        adopted.startNewManagedConversation(); try await Self.wait("new conversation", controller: adopted, home: home) { adopted.managedStatus == .starting && !adopted.isBusy }
        try await Self.waitForFixtureReady(adopted, home: home, phase: "action native readiness")
        #expect(kill(humanPID, 0) == 0)
        let replaced = try #require(adopted.record?.pane)
        let replacement = try await runner.run(executable: tmux, arguments: ["-S", socket, "respawn-pane", "-k", "-t", replaced.id, "/bin/sleep", "86400"], input: nil, environment: env)
        #expect(replacement.status == 0)
        adopted.stopManagedSession(); try await Self.wait("foreign replacement rejected", controller: adopted, home: home) { !adopted.isBusy }
        guard case .failed = adopted.managedStatus else { Issue.record("Stop must reject a replaced process"); return }
        let preserved = try await host.inspect(name: replaced.name, owner: owner, pane: replaced)
        let replacementPID = try #require(preserved?.pid)
        #expect(replacementPID != replaced.pid && kill(Int32(replacementPID), 0) == 0)
        #expect(try await host.inspect(name: replaced.name, owner: owner, pane: nil) == nil)
        adopted.startNewManagedConversation(); try await Self.wait("new conversation", controller: adopted, home: home) { adopted.managedStatus == .starting && !adopted.isBusy }
        try await Self.waitForFixtureReady(adopted, home: home, phase: "action native readiness")
        #expect(adopted.record?.pane?.id != replaced.id)
        #expect(kill(Int32(replacementPID), 0) == 0)
        adopted.stopManagedSession(); try await Self.wait("stop", controller: adopted, home: home) { adopted.managedStatus == .stopped && !adopted.isBusy }
        #expect(kill(Int32(replacementPID), 0) == 0 && kill(humanPID, 0) == 0)
        let untouched = try await runner.run(executable: tmux, arguments: ["-S", socket, "has-session", "-t", "=zeus"], input: nil)
        #expect(untouched.status == 0)
        #expect(kill(Int32(alive.pid), 0) == -1)
    }

    private static let watchdogScript = """
    import os, subprocess, sys, time
    parent = int(sys.argv[1])
    while True:
        try: os.kill(parent, 0)
        except ProcessLookupError: break
        time.sleep(0.25)
    subprocess.run([sys.argv[2], '-S', sys.argv[3], 'kill-server'])
    """

    @Test func privateServerExitsWhenItsFixtureHostDies() async throws {
        await NativeProcessTestGate.acquire()
        defer { NativeProcessTestGate.release() }
        guard let tmux = TmuxExecutable.resolve(),
              let python = ["/opt/homebrew/bin/python3", "/usr/bin/python3"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return }
        let root = URL(fileURLWithPath: "/tmp/zmanaged_" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let socket = root.appendingPathComponent("tmux.sock").path
        let script = root.appendingPathComponent("watchdog.py")
        try Data(Self.watchdogScript.utf8).write(to: script)
        let parent = Process(); parent.executableURL = URL(fileURLWithPath: "/bin/sleep"); parent.arguments = ["86400"]
        try parent.run()
        defer {
            if parent.isRunning { parent.terminate(); parent.waitUntilExit() }
            let cleanup = Process(); cleanup.executableURL = tmux; cleanup.arguments = ["-S", socket, "kill-server"]
            cleanup.standardOutput = FileHandle.nullDevice; cleanup.standardError = FileHandle.nullDevice
            try? cleanup.run(); cleanup.waitUntilExit()
            try? FileManager.default.removeItem(at: root)
        }
        let runner = FoundationProcessRunner()
        let launched = try await runner.run(executable: tmux, arguments: ["-S", socket, "-f", "/dev/null", "new-session", "-d", "-P", "-F", "#{pid}", "-s", "fixture", python, script.path, String(parent.processIdentifier), tmux.path, socket], input: nil)
        #expect(launched.status == 0)
        let server = try #require(Int32(String(decoding: launched.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        parent.terminate(); parent.waitUntilExit()
        let deadline = ContinuousClock.now + .seconds(5)
        while kill(server, 0) == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(kill(server, 0) == -1, "A killed test host must not leave a private server behind")
    }

    private struct FixtureReady: Decodable {
        let pid: Int
        let nativeID: String
    }
    private static func fixtureReady(home: URL) -> FixtureReady? {
        guard let data = try? Data(contentsOf: home.appendingPathComponent("ready.json")) else { return nil }
        return try? JSONDecoder().decode(FixtureReady.self, from: data)
    }
    /// A kernel PID or launch-log append does not prove the fake CLI saved native context.
    /// An atomic marker from that exact process proves it can survive our injected crash.
    private static func waitForFixtureReady(_ controller: ManagedSessionController, home: URL, phase: String) async throws {
        let pane = try #require(controller.record?.pane)
        try await wait(phase, controller: controller, home: home) {
            guard let ready = fixtureReady(home: home), ready.pid == pane.pid,
                  let persisted = try? String(contentsOf: home.appendingPathComponent("native.txt"), encoding: .utf8) else { return false }
            return ready.nativeID == persisted && (controller.record?.conversation?.nativeID.map { $0 == ready.nativeID } ?? true)
        }
    }

    /// Native process creation and SIGINT teardown can outlast the shared 3 s in-memory
    /// helper under concurrent Xcode suites. Keep a bounded process-specific budget,
    /// and report the exact phase plus atomic readiness instead of a bare deadline.
    private static func wait(_ phase: String, controller: ManagedSessionController, home: URL,
                             until condition: @MainActor () -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < end else {
                let ready = fixtureReady(home: home)
                let paused = (try? String(contentsOf: home.appendingPathComponent("init-paused"), encoding: .utf8)) ?? "absent"
                throw ManagedSessionError.command("Fixture phase: \(phase); status: \(controller.managedStatus); busy: \(controller.isBusy); pane: \(String(describing: controller.record?.pane)); ready PID: \(ready?.pid.description ?? "absent"); native ID: \(ready?.nativeID ?? "absent"); init-paused PID: \(paused)")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private static let agentFixture = #"""
import json, os, pathlib, signal, sqlite3, sys, time, uuid
kind = sys.argv[1]
a = sys.argv[2:]
if a == ['--help']:
    print('Private fixture CLI usage')
    sys.exit(0)
home = pathlib.Path(os.environ['HOME'])
home.mkdir(parents=True, exist_ok=True)
with (home / 'launches.jsonl').open('a') as f:
    f.write(json.dumps(a) + '\n')
def value(flag):
    return a[a.index(flag)+1] if flag in a else None
native_file = home / 'native.txt'
if kind == 'claude':
    native = value('--resume') or value('--session-id')
    fresh = '--session-id' in a
    text = a[-1] if fresh else None
elif kind == 'codex':
    fresh = 'resume' not in a
    native = str(uuid.uuid4()) if fresh else a[a.index('resume')+1]
    text = a[-1] if fresh else None
else:
    fresh = '--session' not in a
    native = 'ses_' + uuid.uuid4().hex if fresh else value('--session')
    text = value('--prompt')
if fresh:
    gate = home / 'hold-native-init'
    if gate.exists():
        (home / 'init-paused').write_text(str(os.getpid()))
        while gate.exists():
            time.sleep(.01)
    native_file.write_text(native)
else:
    if native_file.read_text() != native:
        sys.exit(7)
if fresh and kind == 'codex':
    root = pathlib.Path(os.environ['CODEX_HOME']); root.mkdir(parents=True, exist_ok=True)
    with (root/'history.jsonl').open('a') as f:
        f.write(json.dumps({'session_id':native,'text':text}) + '\n')
if fresh and kind == 'opencode':
    root = pathlib.Path(os.environ['XDG_DATA_HOME'])/'opencode'; root.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(root/'opencode.db')
    db.executescript('CREATE TABLE IF NOT EXISTS message(id TEXT PRIMARY KEY,data TEXT); CREATE TABLE IF NOT EXISTS part(message_id TEXT,session_id TEXT,data TEXT);')
    msg = str(uuid.uuid4())
    db.execute('INSERT INTO message VALUES(?,?)',(msg,json.dumps({'role':'user'})))
    db.execute('INSERT INTO part VALUES(?,?,?)',(msg,native,json.dumps({'type':'text','text':text})))
    db.commit(); db.close()
signal.signal(signal.SIGINT, lambda *_: sys.exit(0))
# Publish only after context creation/resume verification and native store initialization.
ready = home / ('ready-' + str(os.getpid()) + '.tmp')
ready.write_text(json.dumps({'pid': os.getpid(), 'nativeID': native}))
ready.replace(home / 'ready.json')
print('M2a fixture ready', flush=True)
for line in sys.stdin:
    if line.strip() == '/exit':
        break
"""#
}

/// Measures the real restart pipeline. Optional per-command latency reproduces machine
/// scheduling pressure without spawning CPU burners or touching other processes.
/// TEST_RUNNER_ZEUS_FX3_DELAY=0.12 exercises the unchanged 10 s phase deadline.
private final class ManagedFixtureProcessTrace: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var tracing = false
    private var rows: [String] = []
    private var current = "none"
    private var repairs = 0
    private var began = ContinuousClock.now
    var ownerRepairs: Int { lock.withLock { repairs } }
    private let delay = Double(ProcessInfo.processInfo.environment["ZEUS_FX3_DELAY"] ?? "0") ?? 0
    func beginRestart() { lock.withLock { tracing = true; rows = []; repairs = 0; began = .now } }
    func endRestart() { lock.withLock { tracing = false } }
    var summary: String { lock.withLock { "elapsed=\(began.duration(to: .now)) commands=\(rows.count) ownerRepairs=\(repairs) current=\(current) recent=\(rows.suffix(8).joined(separator: "; "))" } }
    func run(executable: URL, arguments: [String], input: Data?) async throws -> ProcessResult {
        try await run(executable: executable, arguments: arguments, input: input, environment: ProcessInfo.processInfo.environment)
    }
    func run(executable: URL, arguments: [String], input: Data?, environment: [String: String]) async throws -> ProcessResult {
        let trace = lock.withLock { tracing }
        let name = arguments.dropFirst(3).first ?? "unknown"
        let start = ContinuousClock.now
        if trace { lock.withLock { current = name; if name == "set-option", arguments.contains("@zeus-owner") { repairs += 1 } } }
        if trace, delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        let result = try await FoundationProcessRunner().run(executable: executable, arguments: arguments, input: input, environment: environment)
        if trace { lock.withLock { rows.append("\(name):\(start.duration(to: .now))"); current = "none" } }
        return result
    }
}
