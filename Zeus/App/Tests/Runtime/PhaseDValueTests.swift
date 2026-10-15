import Foundation
import Testing
@testable import Zeus

/// Pure transition checks remain runnable while macOS correctly locks protected journal files.
@MainActor @Suite struct PhaseDValueTests {
    @Test func exactOutcomeDeltasIdempotencyDailyCapAndUserFloorWithoutIO() throws {
        let store = try PersistentRulesStore(fileURL: URL(fileURLWithPath: "/tmp/zeus_absent_" + UUID().uuidString), keyProvider: FixtureJournalKey())
        let now = Date()
        let cases: [(RuleOutcome, RuleOutcomeSource, Double)] = [(.accepted,.explicit,0.1),(.accepted,.actedUnchanged,0.03),(.accepted,.heldRead,0.02),(.undone,.holdShown,-0.1),(.undone,.explicit,-0.3),(.skipped,.shadowDeclined,-0.2),(.skipped,.timedQuestion,-0.1),(.ignored,.resultIgnored,-0.05),(.toggledOff,.explicit,-0.3),(.toggledOn,.explicit,0.1),(.stale,.stale,-0.1)]
        for entry in cases {
            var state = PersistentRulesStore.State()
            state.rules = [.init(id: "rule", sentence: "Use concise updates", trigger: .init(), kind: .passive, status: .active,
                confidence: 0.6, evidence: [], created: now, updated: now, updatedBy: .agent, author: .agent)]
            store.applySignal(&state, entry.0, source: entry.1, ids: ["rule"], eventID: "event", at: now)
            #expect(abs(state.rules[0].confidence - (0.6 + entry.2)) < 0.000001)
            #expect(state.outcomes.count == 1 && state.outcomes[0].delta == entry.2)
            store.applySignal(&state, entry.0, source: entry.1, ids: ["rule"], eventID: "event", at: now)
            #expect(state.outcomes.count == 1)
        }
        var state = PersistentRulesStore.State()
        state.rules = [.init(id: "own", sentence: "My rule", trigger: .init(), kind: .passive, status: .active,
            confidence: 0.2, evidence: [], created: now, updated: now, updatedBy: .user, author: .user)]
        store.applySignal(&state, .undone, source: .explicit, ids: ["own"], eventID: "undo", at: now)
        #expect(state.rules[0].confidence == 0 && state.rules[0].status == .active)
        store.applySignal(&state, .edited, source: .explicit, ids: ["own"], eventID: "edit", at: now)
        #expect(state.rules[0].confidence == 0.6)
        store.applySignal(&state, .accepted, source: .heldRead, ids: ["own"], eventID: "read1", at: now)
        store.applySignal(&state, .accepted, source: .heldRead, ids: ["own"], eventID: "read2", at: now)
        #expect(state.rules[0].confidence == 0.62)
    }
    @Test func retirementThresholdAndFingerprintAreStable() throws {
        let store = try PersistentRulesStore(fileURL: URL(fileURLWithPath: "/tmp/zeus_absent_" + UUID().uuidString), keyProvider: FixtureJournalKey())
        let now = Date(); var state = PersistentRulesStore.State()
        state.rules = [.init(id: "rule", sentence: "Hold quiet updates", trigger: .init(), kind: .passive, status: .active,
            confidence: 0.3, evidence: [], created: now, updated: now, updatedBy: .user, author: .agent)]
        store.applySignal(&state, .skipped, source: .timedQuestion, ids: ["rule"], eventID: "one", at: now)
        #expect(state.rules[0].confidence == 0.2 && state.rules[0].status == .active)
        store.applySignal(&state, .ignored, source: .resultIgnored, ids: ["rule"], eventID: "two", at: now)
        #expect(state.rules[0].status == .retired && state.suppressions.count == 1)
        #expect(state.suppressions[0].until == now.addingTimeInterval(30 * 86400))
        #expect(PersistentRulesStore.fingerprint("Hold quiet updates!", trigger: .init(apps: ["com.test.B", "com.test.A"])) == PersistentRulesStore.fingerprint("hold QUIET updates", trigger: .init(apps: ["com.test.A", "com.test.B"])))
    }
}
