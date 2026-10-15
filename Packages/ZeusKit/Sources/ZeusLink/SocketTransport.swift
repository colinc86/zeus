import Darwin
import Foundation
import ZeusProtocol

// POSIX I/O is confined to dedicated queues. The lock protects descriptor lifetime, so a
// concurrent close cannot cause I/O on a recycled descriptor. No AppKit dependency.
internal func socketAddress(_ path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    let bytes = Array(path.utf8)
    guard !bytes.isEmpty, !bytes.contains(0), bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
        throw BridgeLinkError.invalidSocketPath
    }
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
        destination.copyBytes(from: bytes + [0])
    }
    return address
}

internal func withAddress<T>(_ address: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) rethrows -> T {
    try withUnsafePointer(to: &address) { pointer in
        try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { try body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
}

internal func newSocket() throws -> Int32 {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw BridgeLinkError.system(operation: "socket", code: errno) }
    do { try configureSocket(fd) }
    catch { Darwin.close(fd); throw error }
    return fd
}

private func configureSocket(_ fd: Int32) throws {
    guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw BridgeLinkError.system(operation: "FD_CLOEXEC", code: errno) }
    var noSignal: Int32 = 1
    guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
        throw BridgeLinkError.system(operation: "SO_NOSIGPIPE", code: errno)
    }
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    guard setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
        throw BridgeLinkError.system(operation: "SO_SNDTIMEO", code: errno)
    }
}

internal final class SocketChannel: @unchecked Sendable {
    let messages: AsyncThrowingStream<WireMessage, any Error>
    private let continuation: AsyncThrowingStream<WireMessage, any Error>.Continuation
    private let lock = NSLock()
    private var fd: Int32
    private var isClosed = false
    private let writer = DispatchQueue(label: "ZeusLink.write")

    init(fd: Int32) {
        self.fd = fd
        (messages, continuation) = AsyncThrowingStream.makeStream()
        DispatchQueue(label: "ZeusLink.read").async { [self] in readLoop() }
    }

    static func connect(path: String) async throws -> SocketChannel {
        try await Task.detached {
            var address = try socketAddress(path)
            let fd = try newSocket()
            guard withAddress(&address, { Darwin.connect(fd, $0, $1) }) == 0 else {
                let code = errno; Darwin.close(fd); throw BridgeLinkError.system(operation: "connect", code: code)
            }
            return SocketChannel(fd: fd)
        }.value
    }

    func send(_ message: WireMessage) async throws {
        let data = try NDJSONFramer.encode(message)
        guard data.count <= 4 * 1024 * 1024 + 1 else { throw BridgeLinkError.messageTooLarge }
        try await withCheckedThrowingContinuation { (result: CheckedContinuation<Void, any Error>) in
            writer.async { [self] in
                do {
                    try lock.withLock {
                        guard !isClosed else { throw BridgeLinkError.disconnected }
                        try data.withUnsafeBytes { bytes in
                            guard let base = bytes.baseAddress else { return }
                            var sent = 0
                            while sent < bytes.count {
                                let count = Darwin.send(fd, base.advanced(by: sent), bytes.count - sent, 0)
                                if count < 0 && errno == EINTR { continue }
                                guard count > 0 else { throw BridgeLinkError.system(operation: "send", code: errno) }
                                sent += count
                            }
                        }
                    }
                    result.resume()
                } catch { result.resume(throwing: error); close() }
            }
        }
    }

    func close() {
        lock.withLock {
            guard !isClosed else { return }
            isClosed = true
            _ = Darwin.shutdown(fd, SHUT_RDWR)
        }
    }

    private func readLoop() {
        defer {
            lock.withLock {
                isClosed = true
                _ = Darwin.close(fd)
                fd = -1
            }
        }
        var framer = NDJSONFramer()
        var bytes = [UInt8](repeating: 0, count: 16 * 1024)
        do {
            while true {
                let count = Darwin.recv(fd, &bytes, bytes.count, 0)
                if count < 0 && errno == EINTR { continue }
                if count == 0 { try framer.finish(); continuation.finish(); return }
                guard count > 0 else { throw BridgeLinkError.system(operation: "recv", code: errno) }
                for message in try framer.append(Data(bytes.prefix(count))) { continuation.yield(message) }
            }
        } catch { continuation.finish(throwing: error) }
    }
}

internal final class ListeningSocket: @unchecked Sendable {
    private let fd: Int32
    private let path: String
    private let lock = NSLock()
    private var stopped = false
    private var source: (any DispatchSourceRead)?
    private let inode: ino_t

    init(path: String) throws {
        var address = try socketAddress(path)
        // Reclaim only a same-user stale socket. Never overwrite a regular file or live listener.
        var info = stat()
        if lstat(path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == geteuid() else { throw BridgeLinkError.socketAlreadyExists }
            let probe = try newSocket()
            let connected = withAddress(&address, { Darwin.connect(probe, $0, $1) })
            let code = errno
            Darwin.close(probe)
            guard connected != 0, code == ECONNREFUSED else { throw BridgeLinkError.socketAlreadyExists }
            guard unlink(path) == 0 else { throw BridgeLinkError.system(operation: "unlink stale socket", code: errno) }
        } else if errno != ENOENT { throw BridgeLinkError.system(operation: "lstat", code: errno) }
        let fd = try newSocket()
        guard withAddress(&address, { Darwin.bind(fd, $0, $1) }) == 0 else {
            let code = errno; Darwin.close(fd); throw BridgeLinkError.system(operation: "bind", code: code)
        }
        guard chmod(path, 0o600) == 0, Darwin.listen(fd, 16) == 0, lstat(path, &info) == 0 else {
            let code = errno; Darwin.close(fd); unlink(path); throw BridgeLinkError.system(operation: "listen/chmod", code: code)
        }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            let code = errno; Darwin.close(fd); unlink(path)
            throw BridgeLinkError.system(operation: "nonblocking listener", code: code)
        }
        self.fd = fd; self.path = path; self.inode = info.st_ino
    }

    func run(accept: @escaping @Sendable (SocketChannel) -> Void) {
        lock.withLock {
            guard !stopped, source == nil else { return }
            // shutdown(listeningFD) returns ENOTCONN on macOS and cannot wake a
            // blocking accept. A readiness source needs no idle worker and closes
            // only after its event handler finishes, avoiding descriptor reuse races.
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "ZeusLink.accept"))
            let descriptor = fd
            source.setEventHandler { [weak self] in self?.acceptReady(accept) }
            source.setCancelHandler { _ = Darwin.close(descriptor) }
            self.source = source
            source.resume()
        }
    }

    private func acceptReady(_ accept: @escaping @Sendable (SocketChannel) -> Void) {
        while true {
            let (client, code) = lock.withLock { () -> (Int32, Int32) in
                guard !stopped else { return (-1, ECANCELED) }
                let client = Darwin.accept(fd, nil, nil)
                return (client, errno)
            }
            if client < 0 {
                if code == EINTR { continue }
                if code != EAGAIN && code != EWOULDBLOCK && code != ECANCELED { stop() }
                return
            }
            do {
                // Accepted sockets may inherit O_NONBLOCK; channels retain their
                // existing blocking-reader / bounded-writer semantics.
                let flags = fcntl(client, F_GETFL)
                guard flags >= 0, fcntl(client, F_SETFL, flags & ~O_NONBLOCK) == 0 else {
                    throw BridgeLinkError.system(operation: "blocking channel", code: errno)
                }
                try configureSocket(client)
            } catch { Darwin.close(client); continue }
            let channel = SocketChannel(fd: client)
            if lock.withLock({ stopped }) { channel.close() } else { accept(channel) }
        }
    }

    func stop() {
        lock.withLock {
            guard !stopped else { return }
            stopped = true
            if let source {
                source.cancel()
                self.source = nil
            } else { _ = Darwin.close(fd) }
            var info = stat()
            if lstat(path, &info) == 0, info.st_ino == inode { _ = unlink(path) }
        }
    }

    deinit { stop() }
}
