import AppKit
import SwiftUI
import Testing
import ZeusDesign
@testable import Zeus

@MainActor private func lm4Nodes(_ root: Any) -> [NSObject] {
    var visited: Set<ObjectIdentifier> = []
    func walk(_ value: Any) -> [NSObject] {
        guard let node = value as? NSObject, visited.insert(ObjectIdentifier(node)).inserted else { return [] }
        let selector = NSSelectorFromString("accessibilityChildren")
        let children = node.responds(to: selector) ? (node.perform(selector)?.takeUnretainedValue() as? [Any] ?? []) : []
        return [node] + (children + ((node as? NSView)?.subviews ?? [])).flatMap(walk)
    }
    return walk(root)
}
@MainActor private func lm4Label(_ node: NSObject) -> String {
    for name in ["accessibilityLabel", "accessibilityValue", "accessibilityTitle"] {
        let selector = NSSelectorFromString(name)
        if node.responds(to: selector), let value = node.perform(selector)?.takeUnretainedValue() as? String, !value.isEmpty { return value }
    }
    return ""
}
@Suite(.serialized) @MainActor struct LM4PresentationTests {
    private func mount<V: View>(_ view: V, scheme: ColorScheme = .light, width: CGFloat = 740, height: CGFloat = 500) async throws -> (TestHostingView, NSWindow) {
        ZeusFonts.registerBundled()
        let host = TestHostingView(rootView: view.frame(width: width, height: height, alignment: .topLeading)
            .environment(\.accessibilityEnabled, true).environment(\.zeusFontChoice, .system).environment(\.colorScheme, scheme)
            .buttonStyle(ZeusButtonStyle(.secondary, size: .small)).background(ZeusPalette.for(scheme).panel))
        let window = NSPanel(contentRect: .init(x: -20000, y: -20000, width: width, height: height), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.ignoresMouseEvents = true
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host; window.orderFront(nil)
        for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        return (host, window)
    }
    @Test func waitingRowExposesTruthfulLabelExactTextAndSingleAction() async throws {
        let f = try LM4Fixture(); defer { f.cleanup() }
        f.pending(); f.hold(.draft)
        let item = try #require(f.deliveries.pending.first), hold = try #require(f.deliveries.holds.first)
        var opened = 0
        let (host, window) = try await mount(WaitingLearningRow(item: item, hold: hold, now: f.now, openTerminal: { opened += 1 }).padding(24))
        defer { window.contentView = nil; window.close() }
        let row = try #require(lm4Nodes(host).first { lm4Label($0).hasPrefix("Day reflection,") })
        #expect(lm4Label(row).contains("unsent text in its Terminal"))
        #expect(!lm4Label(row).contains("Unreceived target"))
        #expect((row as AnyObject).accessibilityPerformPress?() == true)
        for _ in 0..<4 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        let expandedLabels = lm4Nodes(host).map(lm4Label)
        #expect(expandedLabels.contains { $0 == item.text || $0 == "Prepared text, not yet received: " + item.text }, "Native AX labels: \(expandedLabels)")
        let action = try #require(lm4Nodes(host).first { lm4Label($0) == "Open waiting delivery in Terminal" })
        #expect((action as AnyObject).accessibilityPerformPress?() == true && opened == 1)
    }
    @Test func readyAndReceivedLinesBothExposeViewAndExactText() async throws {
        for summary in ["Daily summary ready for your assistant", "Sent your daily summary"] {
            let (host, window) = try await mount(ConversationNoticeLine(notice: .init(kind: .learning, createdAt: Date(), summary: summary, actionTitle: "View", detail: "Exact fixture text"), maxWidth: 690, hasAction: false, perform: {}).padding(24))
            defer { window.contentView = nil; window.close() }
            let view = try #require(lm4Nodes(host).first { lm4Label($0) == "View: " + summary })
            #expect((view as AnyObject).accessibilityPerformPress?() == true)
            for _ in 0..<4 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
            let expandedLabels = lm4Nodes(host).map(lm4Label)
            #expect(expandedLabels.contains { $0 == "Exact fixture text" || $0 == "Exact text: Exact fixture text" }, "Native AX labels: \(expandedLabels)")
            #expect(lm4Nodes(host).contains { lm4Label($0) == "Hide: " + summary })
        }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TEST_RUNNER_LM4_RENDER"] == "1" || ProcessInfo.processInfo.environment["LM4_RENDER"] == "1"))
    func lightAndDarkDeliveryFixtures() async throws {
        let f = try LM4Fixture(); defer { f.cleanup() }
        let journal = LM2JournalFake(), viewer = JournalViewerModel(journal: journal, now: f.now)
        viewer.deliveries = f.deliveries; viewer.sentOnly = true
        f.controller.pendingLearningDeliveries = DeliveryHold.Reason.allFixtureCases.enumerated().map { index, reason in
            .init(id: reason.rawValue, kind: index == 0 ? .learning : .reflection, text: "Exact prepared text for this synthetic \(reason.rawValue) fixture.\nNo private journal content.", preparedAt: f.now.addingTimeInterval(-720), sessionLabel: "Unreceived target", learningKind: .digest)
        }
        f.controller.deliveryHolds = DeliveryHold.Reason.allFixtureCases.map { .init(deliveryID: $0.rawValue, kind: .reflection, since: f.now.addingTimeInterval(-720), reason: $0) }
        f.deliveries.canStart = { true }; f.deliveries.reconcile()
        for scheme in [ColorScheme.light, .dark] {
            let prefix = scheme == .light ? "light" : "dark"
            try await render(JournalWindowView(model: viewer), name: prefix + "-waiting", scheme: scheme, height: 810)
            try await render(VStack(alignment: .leading, spacing: 20) {
                ForEach(f.cards.notices.filter { $0.id.hasPrefix("learning-delivery-hold:") }) { notice in
                    ConversationNoticeLine(notice: notice, maxWidth: 680, hasAction: notice.actionTitle != nil, perform: {}, hasSecondaryAction: notice.secondaryTitle != nil)
                }
                ConversationNoticeLine(notice: .init(kind: .learning, createdAt: f.now, summary: "Daily summary ready for your assistant", actionTitle: "View", detail: "Exact text"), maxWidth: 680, hasAction: false, perform: {})
                ConversationNoticeLine(notice: .init(kind: .learning, createdAt: f.now, summary: "Sent your daily summary", actionTitle: "View", detail: "Exact text"), maxWidth: 680, hasAction: false, perform: {})
            }.padding(24), name: prefix + "-delivery-lines", scheme: scheme, height: 350)
            try await render(ManagedTemplateReplacementSheet(replace: {}, cancel: {}), name: prefix + "-replace", scheme: scheme, width: 480, height: 250)
            for edited in [false, true] {
                f.controller.managedSetupStale = .init(tools: true, template: true, templateEdited: edited); f.deliveries.reconcile()
                let notice = try #require(f.cards.notices.first { $0.id.hasPrefix("managed-setup-update:") })
                try await render(VStack(alignment: .leading, spacing: 24) {
                    ConversationNoticeLine(notice: notice, maxWidth: 690, hasAction: true, perform: {}, hasSecondaryAction: edited)
                    ZeusManagedStatusPanel(f.managed.presentation(now: f.now), attachCommand: nil, note: f.managed.note, disabledActions: f.managed.disabledActions, onAction: { _ in }, onCopy: { _ in false })
                }.padding(24), name: prefix + (edited ? "-edited-setup" : "-stale-setup"), scheme: scheme, height: 300)
            }
        }
    }
    private func render<V: View>(_ view: V, name: String, scheme: ColorScheme, width: CGFloat = 740, height: CGFloat) async throws {
        let (host, window) = try await mount(view, scheme: scheme, width: width, height: height)
        defer { window.contentView = nil; window.close() }
        var repo = URL(fileURLWithPath: #filePath); for _ in 0..<4 { repo.deleteLastPathComponent() }
        let out = repo.appendingPathComponent("build/lm4-renders"); try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width) * 2, pixelsHigh: Int(height) * 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = .init(width: width, height: height); host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: out.appendingPathComponent(name + ".png"))
    }
}
private extension DeliveryHold.Reason {
    static var allFixtureCases: [Self] { [.disconnected, .draft, .busy, .olderSetup] }
}
