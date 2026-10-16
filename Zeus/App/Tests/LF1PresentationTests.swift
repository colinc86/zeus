import AppKit
import SwiftUI
import Testing
import ZeusDesign
@testable import Zeus

@MainActor private func lf1Nodes(_ root: Any) -> [NSObject] {
    var visited: Set<ObjectIdentifier> = []
    func walk(_ value: Any) -> [NSObject] {
        guard let node = value as? NSObject, visited.insert(ObjectIdentifier(node)).inserted else { return [] }
        func children(_ method: String, _ attribute: String? = nil) -> [Any] {
            let selector = NSSelectorFromString(method)
            guard node.responds(to: selector) else { return [] }
            return node.perform(selector, with: attribute)?.takeUnretainedValue() as? [Any] ?? []
        }
        return [node] + (children("accessibilityChildren") + children("accessibilityAttributeValue:", "AXChildren")
            + children("accessibilityAttributeValue:", "AXContents") + ((node as? NSView)?.subviews ?? [])).flatMap(walk)
    }
    return walk(root)
}
@MainActor private func lf1Label(_ node: NSObject) -> String {
    for name in ["accessibilityLabel", "accessibilityValue", "accessibilityTitle"] {
        let selector = NSSelectorFromString(name)
        if node.responds(to: selector), let value = node.perform(selector)?.takeUnretainedValue() as? String, !value.isEmpty { return value }
    }
    return ""
}
@Suite(.serialized) @MainActor struct LF1PresentationTests {
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

    @Test func folderActionsAndCoverCancelAreAccessible() async throws {
        let fake = LF1FolderFake(), model = LearningFolderModel(provider: fake)
        var choices = 0; model.pickFolder = { choices += 1; return nil }
        let (host, window) = try await mount(LearningFolderView(model: model, managed: false).padding(24))
        defer { window.contentView = nil; window.close() }
        let choose = try #require(lf1Nodes(host).first { lf1Label($0) == "Choose learnings folder" })
        #expect((choose as AnyObject).accessibilityPerformPress?() == true && choices == 1)
        #expect(!lf1Nodes(host).contains { lf1Label($0) == "Stop keeping a learnings folder" })
        var cancelled = false, disabled = false
        let (confirmation, sheet) = try await mount(CoverPicturesConfirmation(keepCovering: { cancelled = true }, turnOff: { disabled = true }))
        defer { sheet.contentView = nil; sheet.close() }
        let cancel = try #require(lf1Nodes(confirmation).first { lf1Label($0) == "Keep Covering" })
        #expect((cancel as AnyObject).accessibilityPerformPress?() == true && cancelled && !disabled)
    }
    @Test func deleteNotesStartsUncheckedAndForwardsExplicitCheckboxValue() async throws {
        let state = LF1DeleteState()
        let (host, window) = try await mount(DeleteLearningConfirmation(includeAssistantNotes: Binding(get: { state.notes }, set: { state.notes = $0 }),
            cancel: {}, delete: { state.submitted = state.notes }))
        defer { window.contentView = nil; window.close() }
        #expect(!state.notes)
        let checkbox = try #require(lf1Nodes(host).first { lf1Label($0) == "Also delete your assistant's notes" })
        #expect((checkbox as AnyObject).accessibilityPerformPress?() == true)
        #expect(state.notes)
        let delete = try #require(lf1Nodes(host).first { lf1Label($0) == "Delete" })
        #expect((delete as AnyObject).accessibilityPerformPress?() == true && state.submitted == true)
    }
    @Test func journalRowsExposeFinderToVoiceOver() async throws {
        let fake = LF1FolderFake(), folder = LearningFolderModel(provider: fake), journal = LM2JournalFake()
        fake.ownFolder = URL(fileURLWithPath: "/Fixture/Assistant")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let item = JournalItem(id: "finder", time: now, level: .activity, kind: .activity, payload: .init(.init(description: "Synthetic editor activity")))
        try journal.append(item)
        fake.files[item.id] = fake.ownFolder?.appendingPathComponent("Zeus/days/2027-01-15/activity.md")
        let viewer = JournalViewerModel(journal: journal, now: now); viewer.folder = folder
        let (host, window) = try await mount(JournalRecordRow(item: item, sent: false, expanded: false, toggle: {}, delete: {}, folder: folder).padding(24))
        defer { window.contentView = nil; window.close() }
        let legacyActions = lf1Nodes(host).flatMap { node -> [String] in
            let selector = NSSelectorFromString("accessibilityActionNames")
            return node.responds(to: selector) ? (node.perform(selector)?.takeUnretainedValue() as? [String] ?? []) : []
        }
        let actions = lf1Nodes(host).flatMap { node -> [NSAccessibilityCustomAction] in
            let selector = NSSelectorFromString("accessibilityCustomActions")
            let direct = node.responds(to: selector) ? (node.perform(selector)?.takeUnretainedValue() as? [NSAccessibilityCustomAction] ?? []) : []
            let attribute = NSSelectorFromString("accessibilityAttributeValue:")
            let legacy = node.responds(to: attribute) ? (node.perform(attribute, with: "AXCustomActions")?.takeUnretainedValue() as? [NSAccessibilityCustomAction] ?? []) : []
            return direct + legacy
        }
        #expect(actions.contains { $0.name == "Show in Finder" }, "Actions: \(actions.map(\.name)); legacy: \(legacyActions); nodes: \(lf1Nodes(host).map { "\(type(of: $0)): \(lf1Label($0))" })")
        #expect(actions.contains { $0.name == "Delete" })
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TEST_RUNNER_LF1_RENDER"] == "1" || ProcessInfo.processInfo.environment["LF1_RENDER"] == "1"))
    func lightAndDarkFolderFixtures() async throws {
        let name = "lf1-renders-\(UUID())", defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let screen = ScreenPrivacyModel(policies: ObservationSettings(defaults: defaults), privacy: LearnSettings(defaults: defaults))
        screen.policies.edit(3) { $0.enabled = true; $0.consented = true }; screen.permission = .granted
        let fake = LF1FolderFake(), folder = LearningFolderModel(provider: fake)
        let journal = LM2JournalFake(), now = Date(timeIntervalSince1970: 1_800_000_000)
        let item = JournalItem(id: "fixture", time: now, level: .activity, kind: .activity, payload: .init(.init(description: "Used an editor for 12 minutes")))
        try journal.append(item)
        let viewer = JournalViewerModel(journal: journal, now: now); viewer.folder = folder
        for scheme in [ColorScheme.light, .dark] {
            let prefix = scheme == .light ? "light" : "dark"
            for mode in ["managed", "managed-none", "chosen", "none", "error"] {
                fake.managedFolder = mode == "managed" ? URL(fileURLWithPath: "/Fixture/Zeus Assistant") : nil
                fake.ownFolder = ["chosen", "error"].contains(mode) ? URL(fileURLWithPath: "/Fixture/Assistant") : nil
                fake.lastWriteError = mode == "error" ? "Fixture write failure" : nil
                try await render(VStack(alignment: .leading, spacing: 16) {
                    Text("Learn from me").settingsTitle()
                    Text(PrivacySettingsView.caveat).settingsCaption()
                    LearningFolderView(model: folder, managed: mode.hasPrefix("managed"))
                }.padding(24), name: prefix + "-folder-" + mode, scheme: scheme, height: 320)
            }
            try await render(ObservationConsentSheet(enable: {}, cancel: {}), name: prefix + "-focus-consent", scheme: scheme, width: 480, height: 770)
            try await render(ScreenConsentSheet(enable: {}, cancel: {}, heightLimit: 1100), name: prefix + "-screen-consent", scheme: scheme, width: 540, height: 1100)
            try await render(TypingConsentSheet(enable: {}, cancel: {}, heightLimit: 1000), name: prefix + "-typing-consent", scheme: scheme, width: 540, height: 1000)
            fake.lastWriteError = nil; fake.ownFolder = URL(fileURLWithPath: "/Fixture/Assistant")
            fake.files[item.id] = fake.ownFolder?.appendingPathComponent("Zeus/days/2027-01-15/activity.md")
            fake.dayFolder = fake.files[item.id]?.deletingLastPathComponent()
            try await render(JournalWindowView(model: viewer), name: prefix + "-journal", scheme: scheme, height: 420)
            screen.privacy.coverPictures = true
            try await render(ScreenPrivacyView(model: screen).padding(24), name: prefix + "-screen", scheme: scheme, height: 760)
            screen.privacy.coverPictures = false
            try await render(ScreenPrivacyView(model: screen).padding(24), name: prefix + "-screen-uncovered", scheme: scheme, height: 760)
            try await render(CoverPicturesConfirmation(keepCovering: {}, turnOff: {}), name: prefix + "-cover-confirmation", scheme: scheme, width: 480, height: 300)
            try await render(DeleteLearningConfirmation(includeAssistantNotes: .constant(false), cancel: {}, delete: {}), name: prefix + "-delete", scheme: scheme, width: 480, height: 280)
        }
    }
    private func render<V: View>(_ view: V, name: String, scheme: ColorScheme, width: CGFloat = 740, height: CGFloat) async throws {
        let (host, window) = try await mount(view, scheme: scheme, width: width, height: height)
        defer { window.contentView = nil; window.close() }
        var repo = URL(fileURLWithPath: #filePath); for _ in 0..<4 { repo.deleteLastPathComponent() }
        let out = repo.appendingPathComponent("build/lf1-renders"); try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width) * 2, pixelsHigh: Int(height) * 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = .init(width: width, height: height); host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: out.appendingPathComponent(name + ".png"))
    }
}
@MainActor private final class LF1DeleteState { var notes = false; var submitted: Bool? }
