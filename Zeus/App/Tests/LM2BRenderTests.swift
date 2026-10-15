import AppKit
import SwiftUI
import Testing
import ZeusDesign
import ZeusProtocol
@testable import Zeus

/// Owned in-process renders only. All records, screen bytes and stores are synthetic; no AX/screen permission is used.
@MainActor @Suite(.serialized) struct LM2BRenderTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TEST_RUNNER_LM2B_RENDER"] == "1" || ProcessInfo.processInfo.environment["LM2B_RENDER"] == "1"))
    func allThemesAndOppositeSystemAppearances() async throws {
        ZeusFonts.registerBundled()
        let name = "zeus-screen-renders-\(UUID())", defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = EncryptedJournalStore(root: root.appendingPathComponent("journal"), keyProvider: LM2BPrivateKey()), now = Date()
        let frame = Redacted(FrameItem(heic: try FrameRedactor.heic(ScreenTestImages.draw()), width: 1000, height: 600,
            boxes: [.init(x: 0.03, y: 0.08, width: 0.5, height: 0.06, kind: .text)], appName: "Editor", windowTitle: "Example.swift"))
        try journal.appendFrame(frame, item: .init(id: "picture", time: now, level: .screen, app: "com.example.Editor", kind: .frame,
            payload: .init(.init(description: "Editor · Example.swift", details: ["window": "Example.swift"])) ))
        try journal.append(.init(id: "description", time: now, level: .screen, app: "com.example.Editor", kind: .description,
            payload: .init(.init(description: "Reviewing source changes.", details: ["frame_id": "picture", "window": "Example.swift"])) ))
        let viewer = JournalViewerModel(journal: journal, now: now), policies = ObservationSettings(defaults: defaults)
        let learn = LearnFromMe(settings: LearnSettings(defaults: defaults), root: nil), rules = LM2RulesFake()
        learn.settings.enabled = true
        policies.edit(2) { $0.enabled = true; $0.consented = true }
        policies.edit(3) { $0.enabled = true; $0.consented = true }
        let screen = ScreenPrivacyModel(policies: policies, privacy: learn.settings); screen.permission = .granted
        let learning = LearningPresentation(defaults: defaults, learn: learn, policies: policies)
        learning.install(journal: LM2JournalFake(), rules: rules, redactor: LocalRedactor(useOnDeviceModel: false), source: LM2FocusSource())
        defer { learning.stop() }
        let fixed = now.addingTimeInterval(-3 * 86_400)
        _ = try rules.propose([.init(sentence: "Hold routine messages after 18:00", trigger: .init(time: .init(startMinute: 1080, endMinute: 540, weekdays: Set(2...6)))), .init(sentence: "Send a short update to the team", kind: .acts)], at: fixed)
        let cards = CardStore(fileURL: root.appendingPathComponent("cards.json"))
        let settings = AppSettings(defaults: defaults, userDirectory: nil)
        let shell = ShellController(defaults: defaults, cards: cards, settings: settings)
        let navigation = SettingsNavigation(); navigation.tab = .privacy; navigation.showsRules = true
        for theme in ZeusThemeLibrary.load(userDirectory: nil).themes {
            settings.setTheme(id: theme.id)
            for scheme in [ColorScheme.light, .dark] {
                let suffix = theme.id + (scheme == .light ? "-light" : "-dark")
                try await render(ScreenPrivacyView(model: screen), name: suffix + "-screen", theme: theme, scheme: scheme, width: 820, height: 740)
                try await render(ScreenConsentSheet(enable: {}, cancel: {}), name: suffix + "-consent", theme: theme, scheme: scheme, width: 540, height: 700)
                viewer.pictures.selectedID = nil
                try await render(JournalWindowView(model: viewer, settings: settings), name: suffix + "-journal", theme: theme, scheme: scheme, width: 840, height: 520)
                viewer.pictures.selectedID = "picture"
                try await render(JournalPictureDetail(model: viewer.pictures), name: suffix + "-detail", theme: theme, scheme: scheme, width: 820, height: 450)
                viewer.pictures.selectedID = nil
                try await render(RulesSettingsView(model: try #require(learning.rules)), name: suffix + "-rules", theme: theme, scheme: scheme, width: 792, height: 700)
                try await render(SettingsView(settings: settings, managed: shell.managed, cards: cards, status: shell.status, messaging: shell.messaging,
                    preview: shell.messaging, testMessage: shell.testMessage, injectDemo: { _ in }, resetPosition: {}, navigation: navigation,
                    login: shell.login, hotKey: shell.hotKey, activity: shell.surfaceActivity, learn: learn, learning: learning),
                    name: suffix + "-privacy", theme: theme, scheme: scheme, width: 980, height: 1600)
                let attachments = [Attachment(kind: .file, label: "Window · Example.swift", target: "/fixture/window.txt"),
                    Attachment(kind: .url, label: "Page · docs.example.invalid", target: "https://docs.example.invalid"),
                    Attachment(kind: .file, label: "Selection · 42 words", target: "/fixture/selection.txt")]
                try await render(ZeusChipFlow { ForEach(attachments, id: \.id) { item in ZeusAttachmentChip(item, onRemove: {}) } }.padding(16),
                    name: suffix + "-chips", theme: theme, scheme: scheme, width: 420, height: 140)
            }
        }
    }
    private func render<V: View>(_ view: V, name: String, theme: ZeusThemeDefinition, scheme: ColorScheme, width: CGFloat, height: CGFloat) async throws {
        let actual = theme.fixedAppearance ?? scheme
        let host = NSHostingView(rootView: view.frame(width: width, height: height, alignment: .topLeading)
            .environment(\.zeusTheme, theme).environment(\.zeusFontChoice, .system).zeusThemeAppearance(theme)
            .environment(\.colorScheme, actual).buttonStyle(ZeusButtonStyle(.secondary, size: .small)).toggleStyle(ZeusCheckboxStyle())
            .background(theme.palette(for: actual).panel))
        let window = NSWindow(contentRect: .init(x: -20000, y: -20000, width: width, height: height), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: actual == .dark ? .darkAqua : .aqua); window.contentView = host
        defer { window.contentView = nil; window.close() }
        for _ in 0..<3 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        var repo = URL(fileURLWithPath: #filePath); for _ in 0..<4 { repo.deleteLastPathComponent() }
        let out = repo.appendingPathComponent("build/lm2b-renders"); try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for scale in [1, 2] {
            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width) * scale, pixelsHigh: Int(height) * scale,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            bitmap.size = .init(width: width, height: height); host.cacheDisplay(in: host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: out.appendingPathComponent(name + "-\(scale)x.png"))
        }
    }
}
