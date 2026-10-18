import Foundation
import Testing
@testable import Zeus

@MainActor @Suite(.serialized) struct ProactivePresenceTests {
    @Test func reportsOnlyFreshInputWhileEnabledAndDeduplicatesTheTimestamp() {
        let monitor = ProactivePresenceMonitor(); defer { monitor.stop() }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var received: [Date] = []
        var age: TimeInterval = 3600
        monitor.now = { now }; monitor.secondsSinceInput = { age }; monitor.report = { received.append($0) }
        monitor.configure(enabled: true)
        #expect(received.isEmpty)
        age = 5; monitor.check(); monitor.check()
        #expect(received == [now.addingTimeInterval(-5)])
        age = .infinity; monitor.check()
        age = -1; monitor.check()
        #expect(received.count == 1)
        monitor.configure(enabled: false)
        age = 0; monitor.check(); monitor.interacted()
        #expect(received.count == 1)
        monitor.configure(enabled: true)
        #expect(received == [now.addingTimeInterval(-5), now])
    }
    @Test func explicitInteractionRequiresAnEnabledMonitor() {
        let monitor = ProactivePresenceMonitor(); defer { monitor.stop() }
        var received: [Date] = []
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        monitor.now = { now }; monitor.secondsSinceInput = { 3600 }; monitor.report = { received.append($0) }
        monitor.interacted(); #expect(received.isEmpty)
        monitor.configure(enabled: true); monitor.interacted()
        #expect(received == [now])
        monitor.stop(); monitor.interacted(); #expect(received.count == 1)
    }
}
