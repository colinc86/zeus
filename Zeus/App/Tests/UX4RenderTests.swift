import AppKit
import SwiftUI
import Testing
import ZeusDesign
@testable import Zeus

@MainActor @Suite(.serialized) struct UX4RenderTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TEST_RUNNER_UX4_RENDER"] == "1" || ProcessInfo.processInfo.environment["UX4_RENDER"] == "1"))
    func dayTwoThreadLedgerAndLongViewer() async throws {
        ZeusFonts.registerBundled()
        let f = try LM4Fixture(); defer { f.cleanup() }
        let old = f.now.addingTimeInterval(-86400)
        let reflection = (1...32).map { "Day \($0): synthetic work, a break, and time to plan the next step." }.joined(separator: "\n")
        let discarded: [DiscardedLearningDelivery] = [
            .init(id: "brief-old", kind: .brief, text: "Yesterday's exact synthetic morning brief request.", preparedAt: old,
                discardedAt: f.now, reason: .superseded, queueReason: "Replaced by today's brief request", deliveryKindName: "Morning brief request"),
            .init(id: "reflection-old", kind: .reflection, text: reflection, preparedAt: old,
                discardedAt: f.now, reason: .expired, queueReason: DiscardedLearningDelivery.caption(kind: .reflection, reason: .expired), deliveryKindName: "Evening reflection")]
        for item in discarded {
            f.cards.recordNotice(.init(id: "n_" + item.id, kind: .learning, createdAt: old,
                summary: item.deliveryKindName + " ready for your assistant", actionTitle: "View", detail: item.text))
        }
        f.controller.discardedLearningDeliveries = discarded
        f.controller.pendingLearningDeliveries = [.init(id: "brief-today", kind: .brief, text: "Today's exact synthetic brief request.", preparedAt: f.now, sessionLabel: "Fixture")]
        f.deliveries.reconcile()
        let journal = LM2JournalFake(), ledger = JournalViewerModel(journal: journal, now: f.now)
        ledger.deliveries = f.deliveries; ledger.sentOnly = true
        try journal.append(.init(time: f.now, level: .activity, kind: .sentToAssistant,
            payload: .init(.init(description: "Sent the morning summary", text: "Exact received synthetic summary.", details: ["kind": "digest", "sessionLabel": "Claude · Zeus"]))))
        ledger.reload()
        let conversation = ConversationModel(cards: f.cards, messaging: AgentMessagingHub())
        let reader = DocumentViewerModel(); reader.openText(reflection, title: "Evening reflection · Fri 17 Oct", context: "Replaced by a newer reflection")
        defer { reader.close() }
        for scheme in [ColorScheme.light, .dark] { for font in ZeusFontChoice.allCases {
            let name = "ux4-\(scheme)-\(font.rawValue)"
            try await render(VStack(alignment: .leading, spacing: 20) {
                Text("Yesterday").zeusFont(.caption)
                ForEach(f.cards.notices) { notice in
                    ConversationNoticeLine(notice: notice, maxWidth: 348, hasAction: false, perform: {})
                }
            }, name: name + "-thread-day2", scheme: scheme, font: font, width: 396, height: 430)
            try await render(JournalViewerView(model: ledger), name: name + "-ledger", scheme: scheme, font: font, width: 740, height: 650)
            try await render(DocumentViewerView(model: reader, conversation: conversation, back: {}, context: {}),
                name: name + "-long-view", scheme: scheme, font: font, width: 396, height: 650)
        } }
    }
    private func render<V: View>(_ view: V, name: String, scheme: ColorScheme, font: ZeusFontChoice, width: CGFloat, height: CGFloat) async throws {
        let host = TestHostingView(rootView: view.padding(20).frame(width: width, height: height, alignment: .topLeading)
            .environment(\.zeusFontChoice, font).environment(\.colorScheme, scheme)
            .background(ZeusPalette.for(scheme).panel).buttonStyle(ZeusButtonStyle(.secondary, size: .small)))
        let window = NSWindow(contentRect: .init(x: -20000, y: -20000, width: width, height: height), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.animationBehavior = .none; window.contentView = host
        defer { window.contentView = nil; window.close() }
        for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        var repo = URL(fileURLWithPath: #filePath); for _ in 0..<4 { repo.deleteLastPathComponent() }
        let output = repo.appendingPathComponent("build/tmp/ux4/renders")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
    }
}
