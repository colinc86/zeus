import Testing

@MainActor private final class FixtureConcurrency {
    var active = 0
    var maximum = 0
    var completed = 0
    func visit() async {
        await NativeProcessTestGate.acquire()
        defer { NativeProcessTestGate.release() }
        active += 1; maximum = max(maximum, active)
        await Task.yield()
        active -= 1; completed += 1
    }
}

@MainActor struct NativeProcessTestGateTests {
    @Test func independentFixturesNeverOverlap() async {
        let state = FixtureConcurrency()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<3 {
                group.addTask { await state.visit() }
            }
        }
        #expect(state.maximum == 1 && state.active == 0 && state.completed == 3)
    }
}
