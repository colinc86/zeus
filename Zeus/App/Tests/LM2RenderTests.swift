import AppKit
import Foundation
import SwiftUI
import Testing
import ZeusDesign
@testable import Zeus

/// Native, app-local renders of synthetic records. No screen capture, workspace capture or real journal/keychain.
@MainActor @Suite(.serialized) struct LM2RenderTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TEST_RUNNER_LM2_RENDER"] == "1" || ProcessInfo.processInfo.environment["LM2_RENDER"] == "1"))
    func privacyRulesAndConsentRenders() async throws {
        ZeusFonts.registerBundled()
        let suite = "zeus-lm2-render-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let policies = ObservationSettings(defaults: defaults), privacy = LearnSettings(defaults: defaults)
        policies.edit(2) { $0.enabled = true; $0.consented = true; $0.apps = [.init(name: "Xcode", bundleIDs: ["com.apple.dt.Xcode"])] }
        let journal = LM2JournalFake(), store = LM2RulesFake()
        journal.records = [JournalItem(id: "evidence", level: .focus, app: "com.example.Editor", kind: .focus,
            payload: Redacted(JournalPayload(description: "Editor", text: "Window: Review for ‹email›\nDocument: Example.swift — /project"))),
            JournalItem(id: "sent", level: .activity, kind: .sentToAssistant,
                payload: Redacted(JournalPayload(description: "Day reflection", text: "A synthetic day summary with ‹name›.", details: ["sessionLabel": "Claude · Fixture"])))]
        // Fixed fixture date: README captures must not show a freshly-created "1 second ago" rule.
        let now = try #require(ISO8601DateFormatter().date(from: "2026-10-12T03:00:00Z"))
        _ = try store.propose([RuleProposal(sentence: "Hold routine messages after 18:00", trigger: .init(time: .init(startMinute: 1080, endMinute: 540)), evidence: ["evidence"]),
            RuleProposal(sentence: "Send a short update to the team", kind: .acts, evidence: ["evidence"])], at: now)
        let viewer = JournalViewerModel(journal: journal), rules = RulesPaneModel(store: store, journal: viewer)
        for scheme in [ColorScheme.light, .dark] {
            let prefix = scheme == .light ? "light" : "dark"
            try await render(ObservationLevelView(settings: policies, privacy: privacy, hasPermission: { true }, requestPermission: {}), name: prefix + "-scope-private", scheme: scheme, height: 640)
            policies.edit(2) { $0.scope = .chosenApps; $0.apps = [.init(name: "Xcode", bundleIDs: ["com.apple.dt.Xcode"]), .init(name: "Safari", bundleIDs: ["com.apple.Safari"])] }
            try await render(ObservationLevelView(settings: policies, privacy: privacy, hasPermission: { true }, requestPermission: {}), name: prefix + "-scope-chosen", scheme: scheme, height: 440)
            policies.edit(2) { $0.scope = .exceptPrivate }
            try await render(ObservationConsentSheet(enable: {}, cancel: {}), name: prefix + "-consent", scheme: scheme, width: 520, height: 760)
            viewer.sentOnly = false
            try await render(JournalWindowView(model: viewer), name: prefix + "-journal", scheme: scheme, width: 720, height: 620)
            viewer.sentOnly = true
            try await render(JournalWindowView(model: viewer), name: prefix + "-sent", scheme: scheme, width: 720, height: 520)
            try await render(RulesSettingsView(model: rules), name: prefix + "-rules", scheme: scheme, width: 792, height: nil, readmeName: "rules-" + prefix)
        }
    }
    private func render<V: View>(_ view: V, name: String, scheme: ColorScheme, width: CGFloat = 640, height: CGFloat?, readmeName: String? = nil) async throws {
        let palette = ZeusPalette.for(scheme)
        let host = TestHostingView(rootView: view.padding(20).frame(width: width, height: height, alignment: .topLeading)
            .environment(\.zeusFontChoice, .system).environment(\.colorScheme, scheme).background(palette.panel)
            .buttonStyle(ZeusButtonStyle(.secondary, size: .small)).toggleStyle(ZeusCheckboxStyle()))
        let height = height ?? ceil(host.fittingSize.height)
        #expect(height > 0 && height < 2_000)
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: width, height: height), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        var repo = URL(fileURLWithPath: #filePath); for _ in 0..<4 { repo.deleteLastPathComponent() }
        let out = repo.appendingPathComponent("build/lm2-renders")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for scale in [1, 2] {
            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width) * scale, pixelsHigh: Int(height) * scale,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            bitmap.size = NSSize(width: width, height: height)
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: out.appendingPathComponent(name + "-\(scale)x.png"))
            if let readmeName, scale == 2 {
                let readme = repo.appendingPathComponent("docs/readme")
                try FileManager.default.createDirectory(at: readme, withIntermediateDirectories: true)
                #expect(width == 792 && bitmap.pixelsWide == 1584)
                try data.write(to: readme.appendingPathComponent(readmeName + ".png"))
            }
        }
    }
}
