import AppKit
import SwiftUI
import Testing
import ZeusDesign
@testable import Zeus

@Suite(.serialized) @MainActor struct LM2DRenderTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TEST_RUNNER_LM2D_RENDER"] == "1" || ProcessInfo.processInfo.environment["LM2D_RENDER"] == "1"))
    func allThemesAndSystemAppearances() async throws {
        ZeusFonts.registerBundled()
        let name = "zeus-depth-renders-\(UUID())", defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let policies = ObservationSettings(defaults: defaults)
        let store = LM2DManagedRules()
        let rule = try #require(try store.propose([.init(sentence: "Buy the usual coffee", trigger: .init(kind: "spend"), kind: .acts)], at: now).first)
        store.ruleActions = [.init(id: "shadow", ruleID: rule.id, sessionKey: "synthetic", text: "would have bought coffee for €14", undo: nil, created: now, kind: .shadow)]
        store.outcomeEvents = [RuleOutcome.accepted, .undone, .skipped, .ignored, .stale].enumerated().map { index, outcome in
            .init(id: "e-\(index)", ruleID: rule.id, at: now.addingTimeInterval(Double(index) * 86400), outcome: outcome, source: .explicit, delta: 0)
        }
        let journal = LM2JournalFake(); journal.records = [LM2DAppTests.answer(time: now)]
        let viewer = JournalViewerModel(journal: journal, now: now); viewer.showAnswer(id: "journal_answer_fixture")
        let model = RulesPaneModel(store: store, journal: viewer)
        for theme in ZeusThemeLibrary.load(userDirectory: nil).themes {
            for scheme in [ColorScheme.light, .dark] {
                let prefix = theme.id + (scheme == .light ? "-light" : "-dark")
                try await render(RawJournalConsentSheet(level: .screen, allow: {}, cancel: {}), prefix + "-pictures-consent", theme: theme, scheme: scheme, width: 520, height: 330)
                try await render(RawJournalConsentSheet(level: .typed, allow: {}, cancel: {}), prefix + "-words-consent", theme: theme, scheme: scheme, width: 520, height: 330)
                try await render(VStack(alignment: .leading, spacing: 24) {
                    RawJournalAccessView(settings: policies, level: .screen)
                    RawJournalAccessView(settings: policies, level: .typed)
                }.padding(24), prefix + "-switches", theme: theme, scheme: scheme, width: 700, height: 240)
                try await render(JournalWindowView(model: viewer), prefix + "-ledger", theme: theme, scheme: scheme, width: 840, height: 540)
                try await render(RulesSettingsView(model: model).padding(24), prefix + "-rules", theme: theme, scheme: scheme, width: 800, height: 600)
                try await render(RuleEvidenceView(model: model, rule: rule), prefix + "-why", theme: theme, scheme: scheme, width: 440, height: 500)
                try await render(VStack(alignment: .leading, spacing: 20) {
                    ForEach(Array([("Looked at your journal: Tue 14:00–15:30", "View", nil),
                                   ("I'd have sent an update to the team", "OK next time?", "Not this"),
                                   ("Sent an update to the team", "Undo", nil),
                                   ("Retired a rule that never applied: “Prepare a list”", "Review", nil)].enumerated()), id: \.offset) { _, line in
                        ConversationNoticeLine(notice: .init(kind: .learning, createdAt: now, summary: line.0, actionTitle: line.1, secondaryTitle: line.2), maxWidth: 740,
                            hasAction: true, perform: {}, hasSecondaryAction: line.2 != nil)
                    }
                }.padding(24), prefix + "-lines", theme: theme, scheme: scheme, width: 800, height: 300)
            }
        }
    }
    private func render<V: View>(_ view: V, _ name: String, theme: ZeusThemeDefinition, scheme: ColorScheme, width: CGFloat, height: CGFloat) async throws {
        let appearance = theme.fixedAppearance ?? scheme
        let host = NSHostingView(rootView: view.frame(width: width, height: height, alignment: .topLeading)
            .environment(\.zeusTheme, theme).environment(\.zeusFontChoice, .system).zeusThemeAppearance(theme)
            .environment(\.colorScheme, appearance).buttonStyle(ZeusButtonStyle(.secondary, size: .small)).toggleStyle(ZeusCheckboxStyle())
            .background(theme.palette(for: appearance).panel))
        let window = NSWindow(contentRect: .init(x: -20000, y: -20000, width: width, height: height), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua); window.contentView = host
        defer { window.contentView = nil; window.close() }
        for _ in 0..<3 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        var repo = URL(fileURLWithPath: #filePath); for _ in 0..<4 { repo.deleteLastPathComponent() }
        let out = repo.appendingPathComponent("build/lm2d-renders"); try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for scale in [1, 2] {
            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width) * scale, pixelsHigh: Int(height) * scale,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            bitmap.size = .init(width: width, height: height); host.cacheDisplay(in: host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: out.appendingPathComponent(name + "-\(scale)x.png"))
        }
    }
}
