import AppKit
import SwiftUI
import Testing
import ZeusDesign
@testable import Zeus

@Suite(.serialized) @MainActor struct LM2DRenderTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TEST_RUNNER_LM2D_RENDER"] == "1" || ProcessInfo.processInfo.environment["LM2D_RENDER"] == "1"))
    func allThemesAndSystemAppearances() async throws {
        ZeusFonts.registerBundled()
        let name = TestDefaults.suite("zeus-depth-renders"), defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let now = Date(timeIntervalSince1970: 1_792_090_800)
        let policies = ObservationSettings(defaults: defaults)
        let store = LM2DManagedRules()
        let rule = try #require(try store.propose([.init(sentence: "Buy the usual coffee", trigger: .init(kind: "spend"), kind: .acts, evidence: ["evidence"])], at: now.addingTimeInterval(-3 * 86400)).first)
        store.ruleActions = [.init(id: "shadow", ruleID: rule.id, sessionKey: "synthetic", text: "would have bought coffee for €14", undo: nil, created: now, kind: .shadow)]
        store.outcomeEvents = [RuleOutcome.accepted, .undone, .skipped, .ignored, .stale].enumerated().map { index, outcome in
            .init(id: "e-\(index)", ruleID: rule.id, at: now.addingTimeInterval(Double(index - 5) * 3600), outcome: outcome, source: .explicit, delta: 0)
        }
        let journal = LM2JournalFake(); journal.records = [LM2DAppTests.answer(time: now)]
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 180, pixelsHigh: 110, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.darkGray.setFill(); NSRect(x: 0, y: 0, width: 180, height: 110).fill()
        NSColor.gray.setFill(); NSRect(x: 12, y: 40, width: 156, height: 30).fill()
        NSGraphicsContext.restoreGraphicsState()
        let bytes = try #require(bitmap.representation(using: .jpeg, properties: [:]))
        let pictureJSON = try JSONSerialization.data(withJSONObject: ["items": [["id": "picture", "time": "2026-10-15T14:00:00Z", "kind": "screen", "text": "Reviewing a project", "picture": ["mimeType": "image/jpeg", "data": bytes.base64EncodedString()]]]])
        journal.records.append(.init(id: "journal_answer_picture", time: now.addingTimeInterval(60), level: .screen, kind: .sentToAssistant,
            payload: .init(.init(description: "Journal answer", text: String(decoding: pictureJSON, as: UTF8.self), details: ["kind": "journal_answer", "item_count": "1", "pictures": "1", "raw_screen": "allowed", "sessionLabel": "Claude · Zeus", "range": "Thu 14:00–15:30"]))))
        journal.records.append(.init(id: "journal_answer_refused", time: now.addingTimeInterval(-60), level: .screen, kind: .sentToAssistant,
            payload: .init(.init(description: "Journal answer", text: "{\"items\":[]}", details: ["kind": "journal_answer", "item_count": "0", "raw_screen": "not allowed", "raw_typing": "not allowed", "sessionLabel": "Claude · Zeus", "range": "Thu 14:00–15:30"]))))
        journal.records.append(.init(id: "evidence", time: now.addingTimeInterval(-4 * 86400), level: .focus, app: "test.editor", kind: .focus, payload: .init(.init(description: "Planning the usual weekly order", text: "Reviewing the shopping list"))))
        let viewer = JournalViewerModel(journal: journal, now: now); viewer.showAnswer(id: "journal_answer_fixture")
        let model = RulesPaneModel(store: store, journal: viewer)
        let settings = AppSettings(defaults: defaults, userDirectory: nil)
        for theme in ZeusThemeLibrary.load(userDirectory: nil).themes {
            settings.setTheme(id: theme.id)
            for scheme in [ColorScheme.light, .dark] {
                let prefix = theme.id + (scheme == .light ? "-light" : "-dark")
                try await render(VStack(alignment: .leading, spacing: 12) {
                    Text("Learn from me").settingsHeading()
                    LearningStorageWarningView(warnings: [LearningPresentation.storageWaitingMessage])
                }.padding(24), prefix + "-storage-warning", theme: theme, scheme: scheme, width: 700, height: 180)
                try await render(RawJournalConsentSheet(level: .screen, allow: {}, cancel: {}), prefix + "-pictures-consent", theme: theme, scheme: scheme, width: 520, height: 330)
                try await render(RawJournalConsentSheet(level: .typed, allow: {}, cancel: {}), prefix + "-words-consent", theme: theme, scheme: scheme, width: 520, height: 330)
                try await render(VStack(alignment: .leading, spacing: 24) {
                    RawJournalAccessView(settings: policies, level: .screen)
                    RawJournalAccessView(settings: policies, level: .typed)
                }.padding(24), prefix + "-switches", theme: theme, scheme: scheme, width: 700, height: 240)
                try await render(JournalWindowView(model: viewer, settings: settings), prefix + "-ledger", theme: theme, scheme: scheme, width: 840, height: 540)
                viewer.showAnswer(id: "journal_answer_picture")
                try await render(JournalWindowView(model: viewer, settings: settings), prefix + "-ledger-picture", theme: theme, scheme: scheme, width: 840, height: 700)
                viewer.showAnswer(id: "journal_answer_fixture")
                try await render(RulesSettingsView(model: model).padding(24), prefix + "-rules", theme: theme, scheme: scheme, width: 800, height: 600)
                try await render(RuleEvidenceView(model: model, rule: rule), prefix + "-why", theme: theme, scheme: scheme, width: 440, height: 560)
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
        let host = TestHostingView(rootView: view.frame(width: width, height: height, alignment: .topLeading)
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
