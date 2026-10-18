import AppKit
import SwiftUI
import Testing
import ZeusDesign
import ZeusProtocol
@testable import Zeus

private final class FX19Messaging: AgentMessaging {
    var sessions: [ConnectedSession] = []
    func sendUserMessage(_ text: String) async -> MessageSendResult { .delivered }
}

/// FX19: a finished day's delivery lines fold into one (PRIVACY.md §6.1).
@MainActor struct FX19DailyLinesTests {
    private let calendar = Calendar.current
    private func fixture() throws -> (CardStore, ConversationModel, URL, Date) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-fx19-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let now = calendar.date(bySettingHour: 15, minute: 0, second: 0, of: Date()) ?? Date()
        let cards = CardStore(fileURL: root.appendingPathComponent("cards.json"), clock: { now })
        let model = ConversationModel(cards: cards, messaging: FX19Messaging(), clock: { now })
        return (cards, model, root, now)
    }
    private func at(_ now: Date, daysAgo: Int, hour: Double) -> Date {
        calendar.startOfDay(for: now).addingTimeInterval(Double(-daysAgo) * 86_400 + hour * 3_600)
    }
    private func sent(_ id: String, _ summary: String, at date: Date, kind: String = "digest") -> ThreadNotice {
        ThreadNotice(id: id, kind: .learning, createdAt: date, summary: summary, actionTitle: "View", detail: "Exact text", deliveryKindName: kind)
    }

    @Test func finishedDaysFoldAndTodayStaysSeparate() throws {
        let (cards, model, root, now) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for day in [2, 1] {
            _ = cards.recordNotice(sent("n_d\(day)_summary", "Sent the morning summary", at: at(now, daysAgo: day, hour: 9)))
            _ = cards.recordNotice(sent("n_d\(day)_brief", "Sent the morning brief request", at: at(now, daysAgo: day, hour: 9.1), kind: "brief"))
            _ = cards.recordNotice(sent("n_d\(day)_refl", "Sent the evening reflection", at: at(now, daysAgo: day, hour: 18.5), kind: "reflection"))
        }
        _ = cards.recordNotice(sent("n_today_summary", "Sent the morning summary", at: at(now, daysAgo: 0, hour: 9)))
        _ = cards.recordNotice(sent("n_today_brief", "Sent the morning brief request", at: at(now, daysAgo: 0, hour: 9.1), kind: "brief"))
        let thread = model.thread
        let groups = thread.compactMap(\.deliveryGroup)
        #expect(groups.count == 2 && groups.allSatisfy { $0.lines.count == 3 })
        #expect(groups.map(\.summary) == ["Zeus sent your assistant 3 things", "Zeus sent your assistant 3 things"])
        #expect(groups[0].lines.map(\.id) == ["n_d2_summary", "n_d2_brief", "n_d2_refl"])
        // The group sits where the day's first line was; the folded lines are gone from the thread.
        #expect(thread.first { $0.deliveryGroup?.id == groups[0].id }?.timestamp == at(now, daysAgo: 2, hour: 9))
        #expect(!thread.contains { $0.threadNotice?.id == "n_d2_brief" })
        #expect(thread.filter { $0.threadNotice != nil }.map { $0.threadNotice?.id } == ["n_today_summary", "n_today_brief"])
        #expect(thread.allSatisfy { $0.deliveryGroup == nil || ($0.isNotice && !$0.isUser) })
    }

    @Test func liveLinesAndSingleDaysNeverFold() throws {
        let (cards, model, root, now) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let yesterday = { (hour: Double) in self.at(now, daysAgo: 1, hour: hour) }
        _ = cards.recordNotice(sent("n_sent", "Sent the morning summary", at: yesterday(9)))
        _ = cards.recordNotice(ThreadNotice(id: "n_ready", kind: .learning, createdAt: yesterday(9.1), summary: "Morning brief request ready for your assistant", actionTitle: "View", detail: "Request"))
        _ = cards.recordNotice(ThreadNotice(id: "n_notsent", kind: .learning, createdAt: yesterday(12), summary: "Not sent: the morning passed before your assistant could read this brief.", actionTitle: "View", detail: "Request"))
        _ = cards.recordNotice(ThreadNotice(id: "n_replaced", kind: .learning, createdAt: yesterday(13), summary: "Replaced by a newer reflection", actionTitle: "View", detail: "Request"))
        _ = cards.recordNotice(ThreadNotice(id: "n_hold", kind: .learning, createdAt: yesterday(14), summary: "Zeus is waiting to deliver to your assistant: it isn't connected", actionTitle: "Start Assistant"))
        _ = cards.recordNotice(ThreadNotice(id: "n_rule", kind: .learning, createdAt: yesterday(15), summary: "New rule: Hold routine messages after 18:00", actionTitle: "Review"))
        _ = cards.recordNotice(ThreadNotice(id: "n_undone", kind: .learning, createdAt: yesterday(16), summary: "Sent your daily summary", actionTitle: "Undo", resolvedTitle: "Undone"))
        let thread = model.thread
        #expect(thread.compactMap(\.deliveryGroup).isEmpty)  // one finished line only: it stays as it is
        #expect(thread.compactMap { $0.threadNotice?.id } == ["n_sent", "n_ready", "n_notsent", "n_replaced", "n_hold", "n_rule", "n_undone"])
        _ = cards.recordNotice(sent("n_sent2", "Sent a note: first activity today", at: yesterday(9.5), kind: "moment"))
        let folded = model.thread
        #expect(folded.compactMap(\.deliveryGroup).first?.lines.map(\.id) == ["n_sent", "n_sent2"])
        #expect(folded.compactMap { $0.threadNotice?.id } == ["n_ready", "n_notsent", "n_replaced", "n_hold", "n_rule", "n_undone"])
    }

    @Test func dismissedLinesLeaveTheGroupAndMidnightRefolds() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-fx19-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var now = calendar.date(bySettingHour: 23, minute: 0, second: 0, of: Date()) ?? Date()
        let cards = CardStore(fileURL: root.appendingPathComponent("cards.json"), clock: { now })
        let model = ConversationModel(cards: cards, messaging: FX19Messaging(), clock: { now })
        _ = cards.recordNotice(sent("n_a", "Sent the morning summary", at: at(now, daysAgo: 0, hour: 9)))
        _ = cards.recordNotice(sent("n_b", "Sent the morning brief request", at: at(now, daysAgo: 0, hour: 9.1), kind: "brief"))
        _ = cards.recordNotice(sent("n_c", "Sent the evening reflection", at: at(now, daysAgo: 0, hour: 18.5), kind: "reflection"))
        #expect(model.thread.compactMap(\.deliveryGroup).isEmpty)
        now = now.addingTimeInterval(2 * 3_600)  // past midnight: yesterday is finished
        #expect(model.thread.compactMap(\.deliveryGroup).first?.lines.count == 3)
        _ = cards.removeNotice(id: "n_b")
        #expect(model.thread.compactMap(\.deliveryGroup).first?.lines.map(\.id) == ["n_a", "n_c"])
        _ = cards.removeNotice(id: "n_c")
        #expect(model.thread.compactMap(\.deliveryGroup).isEmpty && model.thread.compactMap { $0.threadNotice?.id } == ["n_a"])
    }

    @Test func showLaysTheLinesOutAndHideFoldsThem() async throws {
        ZeusFonts.registerBundled()
        let now = Date()
        let lines = [sent("n_1", "Sent the morning summary", at: now.addingTimeInterval(-86_400)),
                     sent("n_2", "Sent the evening reflection", at: now.addingTimeInterval(-50_000), kind: "reflection")]
        let group = ConversationDeliveryGroup(id: "delivery-group:test", day: now.addingTimeInterval(-86_400), lines: lines)
        var spoken: [String] = []
        let view = ConversationDeliveryGroupLine(group: group, maxWidth: 340, announce: { spoken.append($0) }).frame(width: 380, alignment: .topLeading)
            .environment(\.accessibilityEnabled, true).environment(\.zeusFontChoice, .system)
        let host = TestHostingView(rootView: view)
        let window = NSPanel(contentRect: .init(x: -20000, y: -20000, width: 380, height: 400), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.ignoresMouseEvents = true
        window.contentView = host; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        func labels() -> [String] {
            var visited: Set<ObjectIdentifier> = []
            func walk(_ value: Any, depth: Int) -> [String] {
                guard depth < 60, let node = value as? NSObject, visited.insert(ObjectIdentifier(node)).inserted else { return [] }
                let label = ((node as AnyObject).accessibilityLabel?() ?? nil) ?? ""
                let children = ((node as AnyObject).accessibilityChildren?() ?? nil) ?? []
                return (label.isEmpty ? [] : [label]) + (children + ((node as? NSView)?.subviews ?? [])).flatMap { walk($0, depth: depth + 1) }
            }
            return walk(host, depth: 0)
        }
        func press(_ label: String) -> Bool {
            var visited: Set<ObjectIdentifier> = []
            func find(_ value: Any, depth: Int) -> AnyObject? {
                guard depth < 60, let node = value as? NSObject, visited.insert(ObjectIdentifier(node)).inserted else { return nil }
                if ((node as AnyObject).accessibilityLabel?() ?? nil) == label { return node }
                for child in (((node as AnyObject).accessibilityChildren?() ?? nil) ?? []) + ((node as? NSView)?.subviews ?? []) {
                    if let hit = find(child, depth: depth + 1) { return hit }
                }
                return nil
            }
            return find(host, depth: 0)?.accessibilityPerformPress?() == true
        }
        #expect(labels().contains("Show: Zeus sent your assistant 2 things"))
        #expect(!labels().contains("View: Sent the morning summary"))
        #expect(press("Show: Zeus sent your assistant 2 things"))
        for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        #expect(labels().contains("Hide: Zeus sent your assistant 2 things"))
        #expect(labels().contains("View: Sent the morning summary") && labels().contains("View: Sent the evening reflection"))
        #expect(spoken.last == "Zeus sent your assistant 2 things. Expanded.")
        #expect(press("Hide: Zeus sent your assistant 2 things"))
        for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        #expect(!labels().contains("View: Sent the morning summary"))
    }
}
