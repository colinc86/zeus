import AppKit
import SwiftUI
import Testing
import ZeusDesign
@testable import Zeus

@MainActor private final class ShadowApprovalPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor private final class ShadowApprovalFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-shadow-approval-" + UUID().uuidString)
    let now = Date(timeIntervalSince1970: 1_792_267_200)
    let store: PersistentRulesStore
    let model: RulesPaneModel
    init() throws {
        store = try PersistentRulesStore(fileURL: root.appendingPathComponent("rules.zrules"), keyProvider: FixtureJournalKey())
        let now = now
        model = RulesPaneModel(store: store, journal: JournalViewerModel(journal: LM2JournalFake()), clock: { now })
    }
    func rule(spending: Bool = false) throws -> LearnedRule {
        try #require(try store.propose([.init(sentence: spending ? "Buy the usual coffee" : "Send a short team update",
            trigger: .init(kind: spending ? "spend" : nil), kind: .acts)], at: now).first)
    }
    func action(for rule: LearnedRule, state: RuleActionRecord.State = .pending) -> RuleActionRecord {
        .init(id: "shadow-" + rule.id, ruleID: rule.id, sessionKey: "synthetic", text: "sent a short team update", undo: nil,
              created: now, kind: .shadow, state: state)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@MainActor @Suite(.serialized) struct ShadowApprovalTests {
    @Test func ineligibleActivationLeavesSnapshotAndFileUnchanged() throws {
        let f = try ShadowApprovalFixture(); defer { f.cleanup() }
        let rule = try f.rule()
        _ = try f.store.markShadowShown(id: rule.id)
        let original = f.store.rules, revision = f.store.revision
        let file = f.root.appendingPathComponent("rules.zrules"), bytes = try Data(contentsOf: file)
        for _ in 0..<4 {
            #expect(throws: LearningStorageError.self) { try f.store.setStatus(.active, id: rule.id, at: f.now) }
        }
        #expect(f.store.rules == original && f.store.revision == revision)
        #expect(f.store.outcomeEvents.isEmpty)
        #expect(try Data(contentsOf: file) == bytes)
        f.model.approve(rule)
        #expect(f.model.error == nil && f.store.rules == original)
        let reopened = try PersistentRulesStore(fileURL: file, keyProvider: FixtureJournalKey())
        #expect(reopened.rules == original && reopened.outcomeEvents.isEmpty)
    }

    @Test(arguments: [RuleActionRecord.State.pending, .ignored, .approved, .declined, .off, .undoRequested, .settled])
    func onlyPendingOrIgnoredActualResultsAllowApproval(_ state: RuleActionRecord.State) throws {
        let f = try ShadowApprovalFixture(); defer { f.cleanup() }
        let rule = try f.rule()
        try f.store.recordAction(f.action(for: rule, state: state))
        let eligible = state == .pending || state == .ignored
        #expect(f.model.canApprove(rule) == eligible)
        if eligible {
            try f.store.setStatus(.active, id: rule.id, at: f.now)
            try f.store.setStatus(.active, id: rule.id, at: f.now)
            #expect(f.store.rules.first?.status == .active)
            #expect(f.store.outcomeEvents.count == 1 && f.store.outcomeEvents.first?.outcome == .accepted)
        } else {
            #expect(throws: LearningStorageError.self) { try f.store.setStatus(.active, id: rule.id, at: f.now) }
            #expect(f.store.outcomeEvents.isEmpty && f.store.rules.first?.confidence == 0.6)
        }
    }

    @Test func purchasesAndUnrelatedResultsNeverGrantStandingApproval() throws {
        let f = try ShadowApprovalFixture(); defer { f.cleanup() }
        let rule = try f.rule(), spending = try f.rule(spending: true)
        var purchase = f.action(for: spending); purchase.amount = 14; purchase.currency = "EUR"; purchase.approvalCardID = "purchase"
        try f.store.recordAction(purchase)
        #expect(!f.model.canApprove(rule) && !f.model.canApprove(spending))
        for id in [rule.id, spending.id] {
            #expect(throws: LearningStorageError.self) { try f.store.setStatus(.active, id: id, at: f.now) }
        }
        var mismatchedPurchase = f.action(for: rule); mismatchedPurchase.approvalCardID = "purchase"
        try f.store.recordAction(mismatchedPurchase)
        #expect(!f.model.canApprove(rule))
        #expect(throws: LearningStorageError.self) { try f.store.setStatus(.active, id: rule.id, at: f.now) }
        #expect(f.store.outcomeEvents.isEmpty)
        #expect(f.model.shadowCaption(spending) == "Every purchase asks you first; there's no standing OK.")
    }

    @Test func suggestedAndRetiredActingRulesStillEnterShadow() throws {
        let f = try ShadowApprovalFixture(); defer { f.cleanup() }
        f.store.autonomy = 0
        let rule = try f.rule()
        try f.store.setStatus(.active, id: rule.id, at: f.now)
        #expect(f.store.rules.first?.status == .shadow)
        #expect(f.store.outcomeEvents.first?.outcome == .toggledOn)
        try f.store.recordAction(f.action(for: rule))
        try f.store.setStatus(.active, id: rule.id, at: f.now)
        try f.store.setStatus(.retired, id: rule.id, at: f.now)
        try f.store.setStatus(.active, id: rule.id, at: f.now)
        #expect(f.store.rules.first?.status == .shadow)
        #expect(f.store.outcomeEvents.last?.outcome == .toggledOn)
    }

    @Test func staleShadowRowQuietlyIgnoresWithdrawnEligibility() throws {
        let f = try ShadowApprovalFixture(); defer { f.cleanup() }
        let rule = try f.rule()
        try f.store.recordAction(f.action(for: rule))
        #expect(f.model.canApprove(rule))
        try f.store.declineRule(id: rule.id, at: f.now)
        let before = f.store.rules, outcomes = f.store.outcomeEvents
        f.model.approve(rule)
        #expect(f.model.error == nil)
        #expect(f.store.rules == before && f.store.outcomeEvents == outcomes)
    }

    @Test(arguments: [false, true]) func nativeSettingsRequiresResultAndSeparatesPurchases(dark: Bool) async throws {
        let f = try ShadowApprovalFixture(); defer { f.cleanup() }
        let rule = try f.rule(), spending = try f.rule(spending: true)
        ZeusFonts.registerBundled()
        let scheme: ColorScheme = dark ? .dark : .light
        let host = TestHostingView(rootView: RulesSettingsView(model: f.model).padding(24)
            .frame(width: 792, height: 1100, alignment: .topLeading)
            .environment(\.accessibilityEnabled, true).environment(\.zeusFontChoice, .system)
            .environment(\.colorScheme, scheme)
            .buttonStyle(ZeusButtonStyle(.secondary, size: .small)).toggleStyle(ZeusCheckboxStyle())
            .background(ZeusPalette.for(scheme).panel))
        let window = ShadowApprovalPanel(contentRect: .init(x: -20000, y: -20000, width: 792, height: 1100),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.animationBehavior = .none
        window.contentView = host; window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        let pending = try #require(Self.nodes(host).first { Self.label($0) == "Approve: " + rule.sentence })
        #expect((pending as AnyObject).isAccessibilityEnabled?() == false)
        #expect((pending as AnyObject).accessibilityHelp?() == "Available after the first try")
        #expect(!Self.nodes(host).contains { Self.label($0) == "Approve: " + spending.sentence })
        #expect(f.model.shadowCaption(rule) == "Waiting for its first try. Zeus hasn't seen this rule run yet.")
        _ = (pending as AnyObject).accessibilityPerformPress?()
        #expect(f.store.outcomeEvents.isEmpty)
        try Self.render(host, name: "pending-" + (dark ? "dark" : "light"))
        try f.store.recordAction(f.action(for: rule))
        for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        let approve = try #require(Self.nodes(host).first { Self.label($0) == "Approve: " + rule.sentence })
        #expect((approve as AnyObject).isAccessibilityEnabled?() == true)
        try Self.render(host, name: "ready-" + (dark ? "dark" : "light"))
        #expect((approve as AnyObject).accessibilityPerformPress?() == true)
        #expect(f.store.rules.first?.status == .active)
        _ = (approve as AnyObject).accessibilityPerformPress?()
        f.model.approve(rule)
        #expect(f.store.outcomeEvents.filter { $0.outcome == .accepted }.count == 1)
        #expect(f.store.rules.first?.confidence == 0.7)
        #expect(f.store.rules.last?.status == .shadow)
    }
    private static func render(_ host: NSView, name: String) throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["FX22_RENDER"] ?? environment["TEST_RUNNER_FX22_RENDER"] else { return }
        let output = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
    }
    private static func nodes(_ root: NSObject) -> [NSObject] {
        var seen: Set<ObjectIdentifier> = []
        func walk(_ node: NSObject, depth: Int) -> [NSObject] {
            guard depth < 64, seen.count < 2048, seen.insert(ObjectIdentifier(node)).inserted else { return [] }
            let children: [Any]
            if let accessible = node as? any NSAccessibilityProtocol { children = accessible.accessibilityChildren() ?? [] }
            else {
                let selector = NSSelectorFromString("accessibilityChildren")
                children = node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() as? [Any] ?? [] : []
            }
            return [node] + children.compactMap { $0 as? NSObject }
                .flatMap { walk($0, depth: depth + 1) }
        }
        return walk(root, depth: 0)
    }
    private static func label(_ node: NSObject) -> String? {
        if let accessible = node as? any NSAccessibilityProtocol { return accessible.accessibilityLabel() }
        let selector = NSSelectorFromString("accessibilityLabel")
        return node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() as? String : nil
    }
}
