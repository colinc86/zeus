import Darwin
import Dispatch
import Foundation
import Synchronization

/// Real stdin/stdout adapter. Reads and writes run on dedicated queues, never the MainActor.
/// stdout uses direct, unbuffered POSIX writes; successful completion is the flush boundary.
public enum MCPStdio {
    /// Runs a bridge process until stdin EOF. Diagnostics go exclusively to stderr.
    public static func run(configuration: MCPConfiguration = .init()) async throws {
        let input = try StdioInput()
        let output = try StdioOutput()
        defer { input.stop() }
        try await MCPServer(configuration: configuration).run(input: input.stream, output: output) { message in
            diagnostic(message)
        }
    }
    /// Writes a diagnostic or CLI usage to stderr, never protocol stdout.
    public static func diagnostic(_ message: String) {
        try? FileHandle.standardError.write(contentsOf: Data((message + "\n").utf8))
    }
}

// Immutable stream/source references; DispatchSource cancellation and stream completion
// are thread-safe. The event handler is serialized on its own queue and is the sole reader.
private final class StdioInput: @unchecked Sendable {
    let stream: AsyncThrowingStream<Data, any Error>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    private let source: any DispatchSourceRead

    init() throws {
        guard fcntl(STDIN_FILENO, F_GETFL) >= 0 else {
            throw StdioError.system(operation: "validate stdin", code: errno)
        }
        (stream, continuation) = AsyncThrowingStream.makeStream()
        source = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO,
                                              queue: DispatchQueue(label: "zeus-mcp.stdin"))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var bytes = [UInt8](repeating: 0, count: 16 * 1024)
            let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
            if count < 0 && [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { return }
            if count == 0 { self.stop(); return }
            guard count > 0 else {
                self.continuation.finish(throwing: StdioError.system(operation: "read stdin", code: errno))
                self.source.cancel()
                return
            }
            self.continuation.yield(Data(bytes.prefix(count)))
        }
        continuation.onTermination = { [weak self] _ in self?.stop() }
        source.activate()
    }

    /// No idle timeout polling: readiness/EOF wake the reader, cancellation cancels it.
    /// The process owns stdin; never close or change its shared file-description flags.
    func stop() { source.cancel(); continuation.finish() }
    deinit { source.cancel() }
}

private final class StdioOutput: MCPOutput, Sendable {
    private let queue = DispatchQueue(label: "zeus-mcp.stdout")
    private let originalFlags: Int32
    init() throws {
        let flags = fcntl(STDOUT_FILENO, F_GETFL)
        guard flags >= 0, fcntl(STDOUT_FILENO, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw StdioError.system(operation: "configure stdout", code: errno)
        }
        originalFlags = flags
    }
    deinit { _ = fcntl(STDOUT_FILENO, F_SETFL, originalFlags) }

    func writeAndFlush(_ frame: Data) async throws {
        try Task.checkCancellation()
        let cancelled = CancellationFlag()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                queue.async {
                    do {
                        let deadline = ContinuousClock.now + .seconds(5)
                        try frame.withUnsafeBytes { bytes in
                            guard let base = bytes.baseAddress else { return }
                            var offset = 0
                            while offset < bytes.count {
                                if cancelled.isCancelled { throw CancellationError() }
                                guard ContinuousClock.now < deadline else { throw StdioError.outputTimeout }
                                let count = Darwin.write(STDOUT_FILENO, base.advanced(by: offset), bytes.count - offset)
                                if count > 0 { offset += count; continue }
                                if count < 0 && errno == EINTR { continue }
                                guard count < 0, errno == EAGAIN || errno == EWOULDBLOCK else {
                                    throw StdioError.system(operation: "write stdout", code: errno)
                                }
                                var descriptor = pollfd(fd: STDOUT_FILENO, events: Int16(POLLOUT), revents: 0)
                                let ready = Darwin.poll(&descriptor, 1, 100)
                                if ready < 0 && errno != EINTR { throw StdioError.system(operation: "poll stdout", code: errno) }
                            }
                        }
                        continuation.resume()
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { cancelled.cancel() }
    }
}

private enum StdioError: Error, Sendable, LocalizedError {
    case system(operation: String, code: Int32), outputTimeout
    var errorDescription: String? {
        switch self {
        case .system(let operation, let code): "\(operation) failed (errno \(code))"
        case .outputTimeout: "stdout did not accept a complete MCP frame within 5 seconds"
        }
    }
}

private final class CancellationFlag: Sendable {
    private let value = Mutex(false)
    var isCancelled: Bool { value.withLock { $0 } }
    func cancel() { value.withLock { $0 = true } }
}
