import Darwin
import Dispatch
import Foundation
import ZeusDesign

/// Results of an argument-vector process invocation; no shell is involved.
struct ProcessResult: Sendable {
    var status: Int32
    var stdout: Data = Data()
    var stderr: Data = Data()
}

/// Injectable subprocess boundary for tmux, including literal stdin bytes.
protocol ProcessRunning: Sendable {
    func run(executable: URL, arguments: [String], input: Data?) async throws -> ProcessResult
    /// Explicit client environment; managed tmux clients clear inherited pane identity.
    func run(executable: URL, arguments: [String], input: Data?, environment: [String: String]) async throws -> ProcessResult
}

extension ProcessRunning {
    func run(executable: URL, arguments: [String], input: Data?, environment: [String: String]) async throws -> ProcessResult {
        try await run(executable: executable, arguments: arguments, input: input)
    }
}

/// Runs on a worker queue, drains output through files to avoid pipe deadlocks, and
/// terminates timed-out or cancelled children. Scratch files are user-readable only.
struct FoundationProcessRunner: ProcessRunning {
    var timeout: TimeInterval = 5
    func run(executable: URL, arguments: [String], input: Data? = nil) async throws -> ProcessResult {
        try await run(executable: executable, arguments: arguments, input: input, environment: ProcessInfo.processInfo.environment)
    }
    func run(executable: URL, arguments: [String], input: Data?, environment: [String: String]) async throws -> ProcessResult {
        try Task.checkCancellation()
        let invocation = ProcessInvocation(executable: executable, arguments: arguments, input: input, timeout: timeout, environment: environment)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do { continuation.resume(returning: try invocation.execute()) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { invocation.cancel() }
    }
}

// Configuration is immutable. The lock serializes cancellation, child startup and timeout
// state; Foundation's Process wait/terminate operations support concurrent cancellation.
private final class ProcessInvocation: @unchecked Sendable {
    let executable: URL
    let arguments: [String]
    let input: Data?
    let timeout: TimeInterval
    let environment: [String: String]
    private let lock = NSLock()
    private var child: Process?
    private var cancelled = false
    private var timedOut = false

    init(executable: URL, arguments: [String], input: Data?, timeout: TimeInterval, environment: [String: String]) {
        self.executable = executable; self.arguments = arguments; self.input = input; self.timeout = timeout; self.environment = environment
    }
    func cancel() {
        lock.withLock { cancelled = true; terminateLocked() }
    }
    private func expire() {
        lock.withLock {
            guard let child, child.isRunning else { return }
            timedOut = true; terminateLocked()
        }
    }
    private func terminateLocked() {
        guard let child, child.isRunning else { return }
        child.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.lock.withLock {
                guard let process = self?.child, process.isRunning else { return }
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
    }
    func execute() throws -> ProcessResult {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-process-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        func file(_ name: String, data: Data = Data()) throws -> URL {
            let url = root.appendingPathComponent(name)
            guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw ConnectorError.processIO
            }
            return url
        }
        let inputURL = try file("stdin", data: input ?? Data())
        let outputURL = try file("stdout"), errorURL = try file("stderr")
        let reader = try FileHandle(forReadingFrom: inputURL)
        let output = try FileHandle(forWritingTo: outputURL), error = try FileHandle(forWritingTo: errorURL)
        defer { try? reader.close(); try? output.close(); try? error.close() }
        let process = Process()
        process.executableURL = executable; process.arguments = arguments; process.environment = environment
        process.standardInput = reader; process.standardOutput = output; process.standardError = error
        try lock.withLock {
            guard !cancelled else { throw CancellationError() }
            child = process
            try process.run()
        }
        let deadline = DispatchWorkItem { [weak self] in self?.expire() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0.01, timeout), execute: deadline)
        process.waitUntilExit()
        deadline.cancel()
        try lock.withLock {
            child = nil
            if cancelled { throw CancellationError() }
            if timedOut { throw ConnectorError.processTimeout }
        }
        // tmux diagnostics are small; cap capture rather than retaining arbitrary child output.
        func capture(_ url: URL) throws -> Data {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            return try handle.read(upToCount: 64 * 1024) ?? Data()
        }
        return try .init(status: process.terminationStatus, stdout: capture(outputURL), stderr: capture(errorURL))
    }
}

/// Connector failures are surfaced as queued attempts by the existing delivery ledger.
enum ConnectorError: Error, Sendable, Equatable, LocalizedError {
    case missingTmux, missingTarget, processIO, processTimeout, processExit(Int32)
    case invalidURL, invalidCredentials, httpStatus(Int), invalidHTTPResult
    case inputBusy, inputChanged, inputTooLong, missingTmuxSocket, mismatchedTmuxSocket, missingOpenCodeSession, mismatchedOpenCodeSession, mismatchedOpenCodeEndpoint, unverifiedOpenCodeDestination
    var postponesDelivery: Bool {
        switch self { case .missingTmux, .inputBusy, .inputChanged, .inputTooLong, .missingTmuxSocket, .mismatchedTmuxSocket, .missingOpenCodeSession, .mismatchedOpenCodeSession, .mismatchedOpenCodeEndpoint, .unverifiedOpenCodeDestination: true; default: false }
    }
    var errorDescription: String? {
        let copy = ZeusRuntimeCopy.Delivery.self
        return switch self {
        case .missingTmux: copy.missingTmux
        case .missingTarget: copy.missingPane
        case .processIO: copy.couldNotPrepare
        case .processTimeout: copy.terminalTimedOut
        case .processExit: copy.terminalFailed
        case .invalidURL: copy.openCodeInvalidURL
        case .invalidCredentials: copy.openCodeInvalidUsername
        case .httpStatus(let status): copy.openCodeStatus(status)
        case .invalidHTTPResult: copy.openCodeUnconfirmed
        case .inputBusy: copy.terminalBusy
        case .inputTooLong: copy.terminalTooSmall
        case .inputChanged: copy.terminalChanged
        case .missingTmuxSocket: copy.terminalNotFound
        case .mismatchedTmuxSocket: copy.terminalOtherServer
        case .missingOpenCodeSession: copy.openCodeChooseAgain
        case .mismatchedOpenCodeEndpoint: copy.openCodeSelectionOnOtherServer
        case .unverifiedOpenCodeDestination: copy.openCodeUnknownServer
        case .mismatchedOpenCodeSession: copy.openCodeOtherFolder
        }
    }
}
