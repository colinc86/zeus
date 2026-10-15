import AppKit
import SwiftUI
import Testing
import ZeusDesign
@testable import Zeus

/// In-process cacheDisplay renders of synthetic records; no tap, automation, screen or clipboard access.
@Suite(.serialized) @MainActor struct LM2CTypingRenderTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TEST_RUNNER_LM2C_RENDER"] == "1" || ProcessInfo.processInfo.environment["LM2C_RENDER"] == "1"))
    func allThemesAndSystemAppearances() async throws {
        ZeusFonts.registerBundled()
        let name = "zeus-typing-renders-\(UUID())", defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(), store = EncryptedJournalStore(root: root, keyProvider: LM2BPrivateKey())
        let policies = ObservationSettings(defaults: defaults), privacy = LearnSettings(defaults: defaults)
        policies.edit(4) { $0.enabled = true; $0.consented = true; $0.apps = [.init(name: "Mail", bundleIDs: ["com.apple.mail"]), .init(name: "Safari", bundleIDs: ["com.apple.Safari"])] }
        let model = TypingPrivacyModel(policies: policies, privacy: privacy); model.modelAvailable = true; model.permission = .granted
        let hour = Calendar.current.date(bySettingHour: 14, minute: 0, second: 0, of: now) ?? now
        for (index, topic) in ["Replying to a doctor about rescheduling an appointment", "Drafting a project update for a colleague", "Planning a source change"].enumerated() {
            try store.append(.init(id: "run-\(index)", time: hour.addingTimeInterval(Double(5 + index * 10) * 60), level: .typed,
                app: "com.apple.mail", kind: .typedText, payload: .init(.init(description: "Typing", text: index == 1 ? nil : (index == 2 ? "fix restart race guard state idle" : "hi dr ‹name› can we move thursday my ‹health› is still sore ‹pasted› thanks"),
                    topic: topic, details: ["words_not_kept": "setting"]))))
        }
        let viewer = JournalViewerModel(journal: store, now: now); viewer.level = 4
        let settings = AppSettings(defaults: defaults, userDirectory: nil)
        for theme in ZeusThemeLibrary.load(userDirectory: nil).themes {
            settings.setTheme(id: theme.id)
            for scheme in [ColorScheme.light, .dark] {
                let prefix = theme.id + (scheme == .light ? "-light" : "-dark")
                model.permission = .granted; model.secureInput = false; model.modelAvailable = true
                try await render(TypingPrivacyView(model: model).padding(20), prefix + "-typing", theme: theme, scheme: scheme, width: 820, height: 690)
                try await render(TypingConsentSheet(enable: {}, cancel: {}, heightLimit: 820), prefix + "-consent", theme: theme, scheme: scheme, width: 540, height: 820)
                try await render(TypingConsentSheet(enable: {}, cancel: {}, heightLimit: 540), prefix + "-consent-short", theme: theme, scheme: scheme, width: 540, height: 540)
                try await render(JournalWindowView(model: viewer, settings: settings), prefix + "-journal", theme: theme, scheme: scheme, width: 840, height: 560)
                model.secureInput = true
                try await render(TypingPrivacyView(model: model).padding(20), prefix + "-private-input", theme: theme, scheme: scheme, width: 820, height: 690)
                model.secureInput = false; model.permission = .denied
                try await render(TypingPrivacyView(model: model).padding(20), prefix + "-permission", theme: theme, scheme: scheme, width: 820, height: 730)
                model.modelAvailable = false
                try await render(TypingPrivacyView(model: model).padding(20), prefix + "-model-off", theme: theme, scheme: scheme, width: 820, height: 750)
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
        let out = repo.appendingPathComponent("build/lm2c-renders"); try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for scale in [1, 2] {
            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width) * scale, pixelsHigh: Int(height) * scale,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            bitmap.size = .init(width: width, height: height); host.cacheDisplay(in: host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: out.appendingPathComponent(name + "-\(scale)x.png"))
        }
    }
}
