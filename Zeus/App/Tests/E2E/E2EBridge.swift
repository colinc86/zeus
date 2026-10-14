import Darwin
import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

/// A real bundled bridge child. Pipe handlers drain stdout/stderr off the MainActor;
/// all inbox state is serialized on it. Every wait has a monotonic deadline.
@MainActor
final class E2EBridge {
    let process = Process()
    private let input = Pipe(), output = Pipe(), diagnostics = Pipe()
    private var buffer = Data()
    private(set) var inbox: [JSONValue] = []
    private var failure: String?
    private var stderr = Data()
    private var nextID = 0
    private var outputEnded = false
    private var closed = false
    private let pipeGate = E2EPipeGate()
    private var reader: Task<Void, Never>?
    private var agentChildPIDFile: URL?

    init(socketPath: String, cwd: URL, agent: AgentKind = .claude, pane: String? = nil, tmuxEnvironment: String? = nil, separateAgentParent: Bool = false) throws {
        let executable = try #require(Bundle.main.url(forAuxiliaryExecutable: "zeus-mcp"), "Missing bundled bridge; run scripts/build.sh")
        process.executableURL = executable
        process.arguments = ["--agent", agent.rawValue, "--socket", socketPath]
        if separateAgentParent {
            let pidFile = cwd.appendingPathComponent("agent-child-\(UUID().uuidString).pid")
            agentChildPIDFile = pidFile
            // A real, persistent agent-parent process; no terminal identity variables.
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-c", "import subprocess,sys; child=subprocess.Popen(sys.argv[2:]); open(sys.argv[1],'w').write(str(child.pid)); sys.exit(child.wait())",
                                 pidFile.path, executable.path, "--agent", agent.rawValue, "--socket", socketPath]
        }
        process.currentDirectoryURL = cwd
        var environment = ProcessInfo.processInfo.environment
        // A developer's own tmux pane must never leak into test connector metadata.
        environment.removeValue(forKey: "TMUX"); environment.removeValue(forKey: "TMUX_PANE")
        if let pane {
            environment["TMUX_PANE"] = pane
            if let tmuxEnvironment { environment["TMUX"] = tmuxEnvironment }
        }
        process.environment = environment
        process.standardInput = input; process.standardOutput = output; process.standardError = diagnostics
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else { throw E2EFailure("Cannot disable SIGPIPE on child stdin") }
        let outputFD = output.fileHandleForReading.fileDescriptor
        let diagnosticFD = diagnostics.fileHandleForReading.fileDescriptor
        for fd in [outputFD, diagnosticFD] {
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw E2EFailure("Cannot configure nonblocking pipe reader") }
        }
        let gate = pipeGate
        let (chunks, continuation) = AsyncStream<Data>.makeStream()
        reader = Task { [weak self] in
            // One ordered consumer preserves fragmented JSON frame boundaries.
            for await data in chunks { self?.receive(data) }
        }
        output.fileHandleForReading.readabilityHandler = { handle in
            guard let data = gate.read(outputFD) else { return }
            continuation.yield(data)
            if data.isEmpty { handle.readabilityHandler = nil; continuation.finish() }
        }
        diagnostics.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let data = gate.read(diagnosticFD) else { return }
            if data.isEmpty { handle.readabilityHandler = nil }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.stderr.append(data.prefix(max(0, 64 * 1024 - self.stderr.count)))
            }
        }
        do { try process.run() }
        catch { dispose(); throw error }
    }

    private func receive(_ data: Data) {
        guard !closed else { return }
        if data.isEmpty {
            outputEnded = true
            if !buffer.isEmpty { failure = "Truncated stdout JSON-RPC frame" }
            return
        }
        buffer.append(data)
        do {
            while let newline = buffer.firstIndex(of: 10) {
                let frame = Data(buffer[..<newline])
                guard frame.count <= 4 * 1024 * 1024 else { throw E2EFailure("Oversize stdout frame") }
                let message = try ZeusJSON.decoder().decode(JSONValue.self, from: frame)
                guard message["jsonrpc"] == "2.0", message["id"] != nil || message["method"] != nil else {
                    throw E2EFailure("Non-JSON-RPC output on stdout: \(String(decoding: frame, as: UTF8.self))")
                }
                inbox.append(message)
                buffer.removeSubrange(...newline)
            }
            guard buffer.count <= 4 * 1024 * 1024 else { throw E2EFailure("Oversize partial stdout frame") }
        } catch { failure = "Invalid protocol stdout: \(error)" }
    }

    func send(method: String, params: JSONValue = [:]) throws -> JSONValue {
        nextID += 1
        let id = JSONValue.number(Double(nextID))
        try write(["jsonrpc": "2.0", "id": id, "method": .string(method), "params": params])
        return id
    }
    private func write(_ message: JSONValue) throws {
        guard process.isRunning, !closed else { throw E2EFailure("Bridge exited before write") }
        var data = try ZeusJSON.encoder().encode(message); data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
    }
    func reply(to id: JSONValue) async throws -> JSONValue {
        let envelope = try await take("response \(id)") { $0["id"] == id }
        guard envelope["error"] == nil, let result = envelope["result"] else { throw E2EFailure("JSON-RPC error: \(envelope)") }
        return result
    }
    func rpc(_ method: String, _ params: JSONValue = [:]) async throws -> JSONValue { try await reply(to: send(method: method, params: params)) }
    func initialize() async throws {
        let result = try await rpc("initialize", ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "Zeus E2E", "version": "1"]])
        #expect(result["protocolVersion"] == "2025-06-18")
        #expect(result["instructions"] == .string(ZeusMCP.instructions))
        try write(["jsonrpc": "2.0", "method": "notifications/initialized"])
    }
    func call(_ name: String, _ args: JSONValue = [:]) async throws -> JSONValue {
        let result = try await rpc("tools/call", ["name": .string(name), "arguments": args])
        guard result["isError"] != true, let structured = result["structuredContent"] else { throw E2EFailure("Tool \(name) failed: \(result)") }
        // The text seen by the agent must match the structured tool result.
        guard case .string(let text) = result["content"]?[0]?["text"] else { throw E2EFailure("Missing text content") }
        #expect(try ZeusJSON.decoder().decode(JSONValue.self, from: Data(text.utf8)) == structured)
        return structured
    }
    /// Forces multiple readiness events, including a split multibyte UTF-8 scalar.
    func fragmentedCall(_ name: String, _ args: JSONValue) async throws -> JSONValue {
        nextID += 1
        let id = JSONValue.number(Double(nextID))
        var bytes = try ZeusJSON.encoder().encode(JSONValue.object(["jsonrpc": "2.0", "id": id,
            "method": "tools/call", "params": ["name": .string(name), "arguments": args]]))
        bytes.append(10)
        for byte in bytes {
            try input.fileHandleForWriting.write(contentsOf: Data([byte]))
            await Task.yield()
        }
        return try await reply(to: id)
    }
    func writeUnterminatedFrame() throws {
        try input.fileHandleForWriting.write(contentsOf: Data("{\"jsonrpc\":\"2.0\"".utf8))
    }
    func channel(cardID: String) async throws -> JSONValue {
        let envelope = try await take("channel for \(cardID)") {
            $0["method"] == "notifications/claude/channel" && $0["params"]?["meta"]?["card_id"] == .string(cardID)
        }
        return try #require(envelope["params"])
    }
    func userMessage() async throws -> JSONValue {
        let envelope = try await take("user-message channel") {
            $0["method"] == "notifications/claude/channel" && $0["params"]?["meta"]?["kind"] == "userMessage"
        }
        return try #require(envelope["params"])
    }
    var channels: [JSONValue] { inbox.filter { $0["method"] == "notifications/claude/channel" } }

    private func take(_ description: String, matching: (JSONValue) -> Bool) async throws -> JSONValue {
        let deadline = ContinuousClock.now + .seconds(8)
        while true {
            try Task.checkCancellation()
            if let failure { throw E2EFailure(failure) }
            if let index = inbox.firstIndex(where: matching) { return inbox.remove(at: index) }
            guard (process.isRunning || !outputEnded), ContinuousClock.now < deadline else {
                throw E2EFailure("Timed out or bridge exited awaiting \(description). stderr: \(String(decoding: stderr, as: UTF8.self))")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    func kill() {
        guard process.isRunning else { return }
        if let file = agentChildPIDFile, let text = try? String(contentsOf: file, encoding: .utf8), let pid = Int32(text) {
            _ = Darwin.kill(pid, SIGKILL)
        }
        _ = Darwin.kill(process.processIdentifier, SIGKILL)
    }
    func finish() async throws {
        try input.fileHandleForWriting.close()
        let deadline = ContinuousClock.now + .seconds(3)
        while (process.isRunning || !outputEnded) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        guard !process.isRunning && outputEnded else { kill(); throw E2EFailure("Bridge did not exit on stdin EOF") }
        #expect(process.terminationStatus == 0)
        if let failure { throw E2EFailure(failure) }
    }
    /// Failure cleanup does not wait on the MainActor or leave a child behind.
    func dispose() {
        guard !closed else { return }
        kill(); closed = true
        output.fileHandleForReading.readabilityHandler = nil
        diagnostics.fileHandleForReading.readabilityHandler = nil
        reader?.cancel(); reader = nil
        pipeGate.close {
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
            try? diagnostics.fileHandleForReading.close()
        }
    }
}

struct E2EFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Real CardStore, status resolver and runtime; only clock/preferences are controlled.
/// No windows, user defaults, production sockets, or user history are touched.
@MainActor
final class E2EFixture {
    let directory: URL
    let clock = TestRuntimeClock()
    let routing = FakeRouting()
    let characters = FakeCharacters()
    var cards: CardStore
    var status: AvatarStatusModel
    var runtime: ZeusRuntime
    var children: [E2EBridge] = []
    private let connectors: [any DeliveryConnector]
    init(connectors: [any DeliveryConnector] = [ChannelDeliveryConnector()]) throws {
        directory = URL(fileURLWithPath: "/private/tmp/ze2_" + UUID().uuidString.prefix(8))
        self.connectors = connectors
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cards = CardStore(fileURL: directory.appendingPathComponent("cards.json"), clock: { [clock] in clock.now })
        status = AvatarStatusModel(cards: cards, clock: { [clock] in clock.now })
        runtime = ZeusRuntime(cards: cards, status: status, characters: characters, routing: routing, clock: clock,
                              socketPath: directory.appendingPathComponent("bridge.sock").path,
                              ledgerURL: directory.appendingPathComponent("deliveries.json"), connectors: connectors)
        do { try runtime.start() } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
    func bridge(_ name: String = "assistant", agent: AgentKind = .claude, pane: String? = nil, tmuxEnvironment: String? = nil) async throws -> E2EBridge {
        let cwd = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        let bridge = try E2EBridge(socketPath: runtime.socketPath, cwd: cwd, agent: agent, pane: pane, tmuxEnvironment: tmuxEnvironment)
        children.append(bridge)
        try await bridge.initialize()
        do { try await eventually { self.runtime.sessions.contains { $0.cwd == cwd.path && $0.agent == agent && $0.tmuxPane == pane } } }
        catch { throw E2EFailure("Missing session for \(agent.rawValue):\(cwd.path), pane \(pane ?? "none"). Live sessions: \(runtime.sessions)") }
        return bridge
    }
    func key(_ name: String = "assistant", agent: AgentKind = .claude, pane: String? = nil) -> String {
        var info = proc_bsdinfo()
        precondition(proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) > 0)
        let start = info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
        return agent.rawValue + ":" + directory.appendingPathComponent(name).path + "#\(getpid()).\(start)"
    }
    func answer(_ id: String, text: String = "Yes", option: String? = nil, label: String? = nil) throws {
        try #require(cards.respond(id: id, response: .init(optionID: option, optionLabel: label, text: text, respondedAt: clock.now, device: .mac)))
    }
    func restart() throws {
        runtime.stop()
        cards = CardStore(fileURL: directory.appendingPathComponent("cards.json"), clock: { [clock] in clock.now })
        status = AvatarStatusModel(cards: cards, clock: { [clock] in clock.now })
        runtime = ZeusRuntime(cards: cards, status: status, characters: characters, routing: routing, clock: clock,
                              socketPath: directory.appendingPathComponent("bridge.sock").path,
                              ledgerURL: directory.appendingPathComponent("deliveries.json"), connectors: connectors)
        try runtime.start()
    }
    func stop() {
        for child in children { child.dispose() }
        runtime.stop()
        try? FileManager.default.removeItem(at: directory)
    }
}

/// True when a `zeus_get_responses` result has no items and the given delivery metadata.
/// Ignores other result fields (e.g. polling-mode guidance), which the tool may add over time.
func e2eIsEmptyPoll(_ result: JSONValue, mode: String, push: Bool) -> Bool {
    result["items"] == [] && result["delivery_mode"] == .string(mode) && result["push_active"] == .bool(push)
}

func e2eString(_ value: JSONValue?) throws -> String {
    guard case .string(let string) = value else { throw E2EFailure("Expected string, got \(String(describing: value))") }
    return string
}

@MainActor
final class E2ERuntimeReference {
    weak var value: ZeusRuntime?
    init(_ value: ZeusRuntime) { self.value = value }
}

/// Prevents queued callbacks from reading a recycled descriptor during failure cleanup.
/// Reads are nonblocking; the lock protects only one read or close operation.
private final class E2EPipeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    func read(_ fd: Int32) -> Data? {
        lock.withLock {
            guard !closed else { return nil }
            var bytes = [UInt8](repeating: 0, count: 16 * 1024)
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count < 0 && [EAGAIN, EWOULDBLOCK, EINTR].contains(errno) { return nil }
            return count > 0 ? Data(bytes.prefix(count)) : Data()
        }
    }
    func close(_ body: () -> Void) { lock.withLock { closed = true; body() } }
}
