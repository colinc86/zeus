import Darwin
import Foundation

/// Opt-in measurement of fixture-created native workers; no production instrumentation.
@MainActor struct LG2ThreadAudit {
    let name: String
    let before: Int
    init(_ name: String) { self.name = name; before = Self.threadCount() }
    func finish() {
        guard ProcessInfo.processInfo.environment["ZEUS_TEST_LG2_AUDIT"] == "1" else { return }
        print("LG2_THREADS \(name) before=\(before) after=\(Self.threadCount())")
    }
    private static func threadCount() -> Int {
        var threads: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS, let threads else { return -1 }
        for i in 0..<Int(count) { mach_port_deallocate(mach_task_self_, threads[i]) }
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threads)), vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        return Int(count)
    }
}

#if DEBUG
import AppKit
import ObjectiveC
import Testing

/// Runs one native fixture in an otherwise empty host, so its worker delta is attributable.
@MainActor struct LG2NativeWorkerTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ZEUS_TEST_LG2_AUDIT"] == "1"))
    func peekMatrixWorkerAudit() async throws {
        let original = class_getInstanceMethod(NSAnimation.self, NSSelectorFromString("startAnimation"))!
        let replacement = class_getInstanceMethod(NSAnimation.self, #selector(NSAnimation.lg2StartAnimation))!
        method_exchangeImplementations(original, replacement)
        defer { method_exchangeImplementations(original, replacement) }
        let audit = LG2ThreadAudit("PeekSizing.matrix")
        try PeekSizingTests().renderedPeekFitsWindowAcrossLinesFontsTitlesOptionsAndTailEdges()
        audit.finish()
        // Let finite native animations settle before measuring retained workers.
        try await Task.sleep(for: .seconds(2))
        audit.finish()
    }
}
extension NSAnimation {
    @objc fileprivate func lg2StartAnimation() {
        print("LG2_ANIMATION \(NSStringFromClass(type(of: self))) duration=\(duration) stack=\(Thread.callStackSymbols.prefix(12).joined(separator: " | "))")
        lg2StartAnimation()
    }
}
#endif
