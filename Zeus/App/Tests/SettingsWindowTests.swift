import AppKit
import SwiftUI
import Testing
import ZeusDesign
@testable import Zeus

@MainActor private struct A11NoCredentials: OpenCodePasswordStoring {
    func read() -> String? { nil }
    func save(_ password: String?) {}
}

@MainActor private final class A11OffscreenPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor private func a11AXNodes(_ object: Any) -> [NSObject] {
    var visited: Set<ObjectIdentifier> = []
    func collect(_ object: Any) -> [NSObject] {
        guard let node = object as? NSObject, visited.insert(ObjectIdentifier(node)).inserted else { return [] }
        let selector = NSSelectorFromString("accessibilityChildren")
        let children = node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() as? [Any] ?? [] : []
        let subviews = (node as? NSView)?.subviews ?? []
        return [node] + (children + subviews).flatMap(collect)
    }
    return collect(object)
}

/// Native Settings layout and AX actions, wholly offscreen with isolated defaults/history.
@Suite(.serialized) @MainActor struct SettingsWindowTests {
    @Test func sizePersistsAcrossPreferenceInstances() throws {
        let suite = "zeus-a11-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(SettingsWindowSize.read(from: defaults) == CGSize(width: 572, height: 572))
        SettingsWindowSize.save(CGSize(width: 810, height: 920), to: defaults)
        let restored = try #require(UserDefaults(suiteName: suite))
        #expect(SettingsWindowSize.read(from: restored) == CGSize(width: 810, height: 920))
        SettingsWindowSize.save(CGSize(width: 700, height: 650), to: defaults)
        #expect(SettingsWindowSize.read(from: restored) == CGSize(width: 700, height: 650))
    }

    @Test func invalidAndOffscreenSizesClampToTheMinimumAndScreenOnThePixelGrid() throws {
        let suite = "zeus-a11-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for size in [CGSize(width: -20, height: 20), CGSize(width: CGFloat.nan, height: CGFloat.infinity)] {
            SettingsWindowSize.save(size, to: defaults)
            #expect(SettingsWindowSize.read(from: defaults) == SettingsWindowSize.minimum)
        }
        defaults.set(["width": "bad", "height": -1], forKey: SettingsWindowSize.key)
        #expect(SettingsWindowSize.read(from: defaults) == SettingsWindowSize.minimum)
        SettingsWindowSize.save(CGSize(width: 2400, height: 1800), to: defaults)
        #expect(SettingsWindowSize.read(from: defaults, available: CGSize(width: 1281, height: 799)) == CGSize(width: 1280, height: 798))
        // An unusably small display must not lower the product's minimum size.
        #expect(SettingsWindowSize.read(from: defaults, available: CGSize(width: 500, height: 400)) == SettingsWindowSize.minimum)
        #expect(SettingsWindowSize.clamped(CGSize(width: 801.9, height: 711.2)) == CGSize(width: 800, height: 710))
        // Clamping for a temporary smaller screen doesn't overwrite the saved preference.
        #expect(SettingsWindowSize.read(from: defaults) == CGSize(width: 2400, height: 1800))
    }

    @Test func nativeWindowRestoresResizableContentAndGeneralJumpsScrollToTheirSections() async throws {
        let suite = "zeus-a11-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-a11-\(UUID())")
        let settings = AppSettings(defaults: defaults, userDirectory: nil, passwordStore: A11NoCredentials())
        let cards = CardStore(fileURL: root.appendingPathComponent("cards.json"))
        let hub = AgentMessagingHub()
        let managed = ManagedAssistantModel(settings: settings, controller: { nil })
        let status = AvatarStatusModel(cards: cards)
        let navigation = SettingsNavigation()
        let view = SettingsView(settings: settings, managed: managed, cards: cards, status: status, messaging: hub,
            preview: hub, testMessage: ComposeModel(cards: cards, messaging: hub), injectDemo: { _ in }, resetPosition: {},
            navigation: navigation, login: LoginItemModel(), hotKey: GlobalHotKey(), activity: SurfaceActivity())
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        host.sizingOptions = []
        let window = A11OffscreenPanel(contentRect: CGRect(x: -10000, y: -10000, width: 572, height: 572),
            styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        defer {
            window.orderOut(nil); window.contentView = nil; window.close()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        window.contentView = host
        SettingsWindowSize.restore(window, from: defaults, screen: nil)
        #expect(window.styleMask.contains(.resizable))
        #expect(window.contentMinSize == SettingsWindowSize.minimum)
        #expect(window.contentResizeIncrements == CGSize(width: ZeusTheme.pixel, height: ZeusTheme.pixel))
        window.orderFront(nil)
        func settle() async throws {
            for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        }
        func scrollView(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
        }
        func jump(_ section: GeneralSettingsSection) throws {
            let button = try #require(a11AXNodes(host).first {
                (($0 as AnyObject).accessibilityLabel?() ?? nil) == "Jump to \(section.rawValue)"
            })
            #expect((button as AnyObject).accessibilityPerformPress?() == true)
        }
        try await settle()
        let scroll = try #require(scrollView(in: host))
        let top = scroll.contentView.bounds.minY
        let smallViewport = scroll.contentView.bounds.height
        try jump(.history); try await settle()
        #expect(scroll.contentView.bounds.minY > top + 100)
        try await render(host, name: "minimum-history")
        try jump(.updates); try await settle()
        #expect(abs(scroll.contentView.bounds.minY - top) < 1)
        for section in [GeneralSettingsSection.sounds, .shortcut] {
            try jump(section); try await settle()
            #expect(scroll.contentView.bounds.minY > top)
        }
        try jump(.updates); try await settle()
        try await render(host, name: "minimum")
        window.setContentSize(CGSize(width: 800, height: 900)); try await settle()
        #expect(host.bounds.size == CGSize(width: 800, height: 900))
        #expect(scroll.contentView.bounds.height > smallViewport + 250)
        try await render(host, name: "expanded")
        navigation.tab = .character; try await settle()
        #expect(!a11AXNodes(host).contains {
            (($0 as AnyObject).accessibilityLabel?() ?? nil)?.hasPrefix("Jump to ") == true
        })
    }

    private func render(_ host: NSView, name: String) async throws {
        guard ProcessInfo.processInfo.environment["ZEUS_A11_RENDER"] == "1" else { return }
        let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        let png = try #require(image.representation(using: .png, properties: [:]))
        var worktree = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { worktree.deleteLastPathComponent() }
        let out = worktree.appendingPathComponent("build/a11-renders")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try png.write(to: out.appendingPathComponent("settings-\(name).png"))
    }
}
