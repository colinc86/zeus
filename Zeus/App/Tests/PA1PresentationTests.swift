import AppKit
import SwiftUI
import Testing
import ZeusDesign
import ZeusProtocol
@testable import Zeus

@MainActor @Suite(.serialized) struct PA1PresentationTests {
    private func mount<V: View>(_ view: V, width: CGFloat, height: CGFloat, scheme: ColorScheme, font: ZeusFontChoice) async throws -> (TestHostingView, NSWindow) {
        ZeusFonts.registerBundled()
        let host = TestHostingView(rootView: view.padding(16).frame(width: width, height: height, alignment: .topLeading)
            .environment(\.colorScheme, scheme).environment(\.zeusFontChoice, font)
            .environment(\.accessibilityEnabled, true).environment(\.zeusAnimationsActive, false)
            .background(ZeusPalette.for(scheme).panel))
        let window = NSPanel(contentRect: .init(x: -20000, y: -20000, width: width, height: height), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.animationBehavior = .none
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host; window.orderFront(nil)
        for _ in 0..<4 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        return (host, window)
    }
    @Test func morningBriefCheckboxUsesModeDefaultAndPersistsAnExplicitChoice() async throws {
        let suite = "pa1-ui-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = MorningBriefSettings(defaults: defaults)
        #expect(settings.effectiveEnabled(managed: true) && !settings.effectiveEnabled(managed: false))
        let (host, window) = try await mount(MorningBriefSettingsView(settings: settings, managed: false), width: 520, height: 360, scheme: .light, font: .system)
        defer { window.contentView = nil; window.close() }
        let node = try #require(jumpAXNodes(host).first { ($0 as AnyObject).accessibilityRole?() == .checkBox && ($0 as AnyObject).accessibilityLabel?() == "Ask my assistant for a morning brief" })
        #expect((node as AnyObject).accessibilityPerformPress?() == true)
        #expect(settings.effectiveEnabled(managed: false))
        #expect(MorningBriefSettings(defaults: defaults).effectiveEnabled(managed: false))
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TEST_RUNNER_PA1_RENDER"] == "1" || ProcessInfo.processInfo.environment["PA1_RENDER"] == "1"))
    func proactiveFixtures() async throws {
        let suite = "pa1-renders-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let settings = MorningBriefSettings(defaults: defaults)
        let cards = CardStore(fileURL: root.appendingPathComponent("cards.json")), fake = FB1RatingsFake()
        let model = MessageRatingsModel(cards: cards, source: { fake }), card = PA1AppTests.card()
        cards.add(card); fake.mutedDecisions[card.id] = card.muteDecision
        for scheme in [ColorScheme.light, .dark] {
            for font in [ZeusFontChoice.pixel, .system] {
                let prefix = "pa1-\(scheme == .dark ? "dark" : "light")-\(font.rawValue)"
                for schedule in MorningBriefSchedule.allCases {
                    settings.schedule = schedule
                    try await render(MorningBriefSettingsView(settings: settings, managed: true), name: prefix + "-settings-" + schedule.rawValue, width: 520, height: 360, scheme: scheme, font: font)
                }
                model.hide(card.id)
                try await render(MutedMessageLine(card: card, model: model), name: prefix + "-held-collapsed", width: 400, height: 80, scheme: scheme, font: font)
                model.show(card.id)
                try await render(PA1HeldFixture(card: card, model: model), name: prefix + "-held-expanded", width: 400, height: 310, scheme: scheme, font: font)
                model.dailyHour = { 0 }; model.reconcile()
                if let notice = cards.notices.first {
                    try await render(ConversationNoticeLine(notice: notice, maxWidth: 368, hasAction: true, perform: {}, hasSecondaryAction: false, performSecondary: {}), name: prefix + "-held-day", width: 400, height: 100, scheme: scheme, font: font)
                }
            }
        }
    }
    private func render<V: View>(_ view: V, name: String, width: CGFloat, height: CGFloat, scheme: ColorScheme, font: ZeusFontChoice) async throws {
        let (host, window) = try await mount(view, width: width, height: height, scheme: scheme, font: font)
        defer { window.contentView = nil; window.close() }
        var repo = URL(fileURLWithPath: #filePath); for _ in 0..<4 { repo.deleteLastPathComponent() }
        let out = repo.appendingPathComponent("build/pa1-renders")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width) * 2, pixelsHigh: Int(height) * 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = .init(width: width, height: height); host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: out.appendingPathComponent(name + ".png"))
    }
}
private struct PA1HeldFixture: View {
    let card: Card
    let model: MessageRatingsModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MutedMessageLine(card: card, model: model)
            ZeusBubble(.agent, muted: true, maxWidth: 368) {
                HStack {
                    Text(card.title ?? "").zeusFont(.button)
                    Spacer()
                    MessageRatingButton(card: card, model: model, hovered: true)
                }
                Text(card.body).zeusFont(.body)
                MessageRatingInline(card: card, model: model)
            }
            MutedMessageReason(card: card, model: model)
        }
    }
}
