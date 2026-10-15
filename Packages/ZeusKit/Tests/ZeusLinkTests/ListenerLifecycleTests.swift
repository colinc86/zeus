import Foundation
import Testing
@testable import ZeusLink

private final class WeakListener {
    weak var value: ListeningSocket?
    init(_ value: ListeningSocket) { self.value = value }
}

@Test func idleStoppedListenersReleaseWithoutAConnection() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("zlg2_" + UUID().uuidString.prefix(8))
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var weakListeners: [WeakListener] = []
    for index in 0..<64 {
        let path = root.appendingPathComponent("s\(index)").path
        let listener = try ListeningSocket(path: path)
        weakListeners.append(WeakListener(listener))
        listener.run { $0.close() }
        // Give the previous blocking implementation time to enter accept.
        try await Task.sleep(for: .milliseconds(2))
        listener.stop()
        #expect(!FileManager.default.fileExists(atPath: path))
    }
    let deadline = ContinuousClock.now + .seconds(2)
    while weakListeners.contains(where: { $0.value != nil }) && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(weakListeners.allSatisfy { $0.value == nil }, "Stopped listeners must not be retained by idle accept workers")
}

@Test func oldListenerCancellationDoesNotUnlinkItsReplacement() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("zlg2_" + UUID().uuidString.prefix(8))
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("bridge.sock").path
    let old = try ListeningSocket(path: path)
    old.run { $0.close() }
    old.stop()
    let replacement = try ListeningSocket(path: path)
    defer { replacement.stop() }
    replacement.run { $0.close() }
    old.stop()
    #expect(FileManager.default.fileExists(atPath: path))
}
