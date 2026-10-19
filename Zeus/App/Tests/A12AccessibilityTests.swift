import AppKit
import SwiftUI
import Testing
import ZeusDesign
import ZeusProtocol
@testable import Zeus

@MainActor private struct A12NoCredentials: OpenCodePasswordStoring {
    func read() -> String? { nil }
    func save(_ password: String?) {}
}
@MainActor private final class A12Panel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// In-process VoiceOver tree inspection: no AX permission, global events, recording or real preferences.
@MainActor private func a12Nodes(_ root: Any) -> [NSObject] {
    var seen: Set<ObjectIdentifier> = []
    func walk(_ object: Any) -> [NSObject] {
        guard let node = object as? NSObject, seen.insert(ObjectIdentifier(node)).inserted else { return [] }
        func children(_ name: String, _ argument: String? = nil) -> [Any] {
            let selector = NSSelectorFromString(name)
            guard node.responds(to: selector) else { return [] }
            return node.perform(selector, with: argument)?.takeUnretainedValue() as? [Any] ?? []
        }
        return [node] + (children("accessibilityChildren") + children("accessibilityAttributeValue:", "AXChildren")
            + children("accessibilityAttributeValue:", "AXContents") + ((node as? NSView)?.subviews ?? [])).flatMap(walk)
    }
    return walk(root)
}
@MainActor private func a12String(_ node: NSObject, _ name: String) -> String? {
    let selector = NSSelectorFromString(name)
    let value = node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() : nil
    if let text = value as? String { return text }
    if let number = value as? NSNumber { return number.stringValue }
    let attribute = ["accessibilityValueDescription": "AXValueDescription"][name]
    if let attribute, node.responds(to: NSSelectorFromString("accessibilityAttributeValue:")) {
        return node.perform(NSSelectorFromString("accessibilityAttributeValue:"), with: attribute)?.takeUnretainedValue() as? String
    }
    return nil
}
@MainActor private func a12Description(_ node: NSObject) -> String {
    ["accessibilityRole", "accessibilityLabel", "accessibilityTitle", "accessibilityValue", "accessibilityValueDescription", "accessibilityHelp"]
        .compactMap { a12String(node, $0) }.joined(separator: " | ")
}

@MainActor private final class A12Fixture {
    let suite = TestDefaults.suite("zeus-a12")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-a12-\(UUID())")
    let defaults: UserDefaults
    let settings: AppSettings
    let cards: CardStore
    let hub = AgentMessagingHub()
    let controller = TruthManagedController()
    let managed: ManagedAssistantModel
    let learn: LearnFromMe
    var windows: [A12Panel] = []
    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        settings = AppSettings(defaults: defaults, userDirectory: nil, passwordStore: A12NoCredentials())
        cards = CardStore(fileURL: root.appendingPathComponent("cards.json"))
        let controller = controller
        managed = ManagedAssistantModel(settings: settings, controller: { controller })
        managed.refreshAvailability()
        learn = LearnFromMe(settings: LearnSettings(defaults: defaults), root: root.appendingPathComponent("Activity"),
                            source: { A12NoActivity() })
    }
    func mount<V: View>(_ view: V, width: CGFloat = 572, height: CGFloat = 1200, referenceColor: Color? = nil) async throws -> TestHostingView {
        let host = TestHostingView(rootView: AnyView(view.padding(24).frame(width: width)
            .overlay(alignment: .topLeading) {
                if let referenceColor { Rectangle().fill(referenceColor).frame(width: 4, height: 4).accessibilityHidden(true) }
            }
            .buttonStyle(ZeusButtonStyle(.secondary, size: .small)).toggleStyle(ZeusCheckboxStyle())
            .environment(\.accessibilityEnabled, true).environment(\.zeusFontChoice, .system)
            .environment(\.zeusAnimationsActive, false)))
        let window = A12Panel(contentRect: CGRect(x: -20000, y: -20000, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.ignoresMouseEvents = true
        window.contentView = host; windows.append(window); window.orderFront(nil)
        try await settle(host)
        return host
    }
    func settle(_ host: NSView) async throws {
        for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
    }
    func button(_ label: String, in host: NSView) throws -> NSObject {
        try #require(a12Nodes(host).first { a12String($0, "accessibilityLabel") == label && a12String($0, "accessibilityRole") == "AXButton" }, "Missing button: \(label)")
    }
    func evidence(_ host: NSView, name: String) throws {
        guard ProcessInfo.processInfo.environment["ZEUS_A12_EVIDENCE"] == "1" || ProcessInfo.processInfo.environment["TEST_RUNNER_ZEUS_A12_EVIDENCE"] == "1" else { return }
        var repo = URL(fileURLWithPath: #filePath); for _ in 0..<4 { repo.deleteLastPathComponent() }
        let out = repo.appendingPathComponent("build/a12-evidence")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let text = a12Nodes(host).map(a12Description).filter { !$0.isEmpty }.joined(separator: "\n")
        try text.write(to: out.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
        let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.needsDisplay = true; host.displayIfNeeded()
        host.cacheDisplay(in: host.bounds, to: image)
        try #require(image.representation(using: .png, properties: [:])).write(to: out.appendingPathComponent(name + ".png"))
    }
    func tabLabels(_ host: NSView) -> [String] {
        guard let window = host.window else { return [] }
        let controls = a12Nodes(host).filter { ["AXButton", "AXCheckBox", "AXSlider", "AXPopUpButton"].contains(a12String($0, "accessibilityRole") ?? "") }
        var visited: Set<ObjectIdentifier> = [], labels: [String] = []
        for _ in 0..<80 {
            window.selectNextKeyView(nil)
            guard let view = window.firstResponder as? NSView, visited.insert(ObjectIdentifier(view)).inserted else { break }
            let frame = window.convertToScreen(view.convert(view.bounds, to: nil))
            let matching = controls.first { node in
                guard let rect = (node as AnyObject).accessibilityFrame?() else { return false }
                return rect.insetBy(dx: -1, dy: -1).contains(CGPoint(x: frame.midX, y: frame.midY))
            }
            labels.append(matching.flatMap { a12String($0, "accessibilityLabel") ?? a12String($0, "accessibilityTitle") } ?? "Unmatched: \(frame)")
        }
        return labels
    }
    func focusedLabel(_ host: NSView) -> String? {
        guard let window = host.window, let view = window.firstResponder as? NSView else { return nil }
        let frame = window.convertToScreen(view.convert(view.bounds, to: nil))
        return a12Nodes(host).first { node in
            guard ["AXButton", "AXCheckBox", "AXSlider", "AXPopUpButton"].contains(a12String(node, "accessibilityRole") ?? ""),
                  let rect = (node as AnyObject).accessibilityFrame?() else { return false }
            return rect.insetBy(dx: -1, dy: -1).contains(CGPoint(x: frame.midX, y: frame.midY))
        }.flatMap { a12String($0, "accessibilityLabel") ?? a12String($0, "accessibilityTitle") }
    }
    func rendersFocusRing(_ label: String, in host: NSView) throws -> Bool {
        let node = try button(label, in: host)
        let window = try #require(host.window)
        let screenFrame = try #require((node as AnyObject).accessibilityFrame?())
        let rect = host.convert(window.convertFromScreen(screenFrame), from: nil)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.needsDisplay = true; host.displayIfNeeded(); host.cacheDisplay(in: host.bounds, to: bitmap)
        // Compare to the same token rendered through the same display profile, not an sRGB number
        // interpreted as device RGB (the offscreen bitmap can be color-managed).
        let target = try #require(bitmap.colorAt(x: 2, y: 2)?.usingColorSpace(.deviceRGB))
        let scaleX = CGFloat(bitmap.pixelsWide) / host.bounds.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / host.bounds.height
        let y = Int((host.isFlipped ? rect.midY : host.bounds.height - rect.midY) * scaleY)
        for x in Int(rect.minX * scaleX)..<Int((rect.minX + 4) * scaleX) {
            guard x >= 0, y >= 0, x < bitmap.pixelsWide, y < bitmap.pixelsHigh,
                  let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            if abs(pixel.redComponent - target.redComponent) < 0.01 && abs(pixel.greenComponent - target.greenComponent) < 0.01 && abs(pixel.blueComponent - target.blueComponent) < 0.01 && pixel.alphaComponent > 0.9 { return true }
        }
        return false
    }
    func cleanup() {
        learn.stop(); managed.createFolder = nil
        for w in windows { w.orderOut(nil); w.contentView = nil; w.close() }
        settings.stopWatchingUserFolders(); defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}
@MainActor private final class A12NoActivity: ActivityEventSource {
    var secondsSinceLastInput: TimeInterval { 0 }
    var frontmostApp: (bundleID: String?, name: String?)? { nil }
    var displayCount: Int { 1 }
    func start(_ handler: @escaping @MainActor (ActivitySignal) -> Void) {}
    func stop() {}
}

@Suite(.serialized) @MainActor struct A12AccessibilityTests {
    @Test func auditNativeTrees() async throws {
        let f = try A12Fixture(); defer { f.cleanup() }
        let appearance = try await f.mount(AppearanceSettingsView(settings: f.settings))
        try f.evidence(appearance, name: "appearance")
        let general = try await f.mount(GeneralSettingsView(settings: f.settings, login: LoginItemModel(), hotKey: GlobalHotKey(), cards: f.cards))
        try f.evidence(general, name: "general")
        let privacy = try await f.mount(PrivacySettingsView(learn: f.learn))
        try f.evidence(privacy, name: "privacy")
        f.settings.fadeZeusWhenIdle = true
        let character = try await f.mount(CharacterSettingsView(settings: f.settings, resetPosition: {}), height: 1400)
        try f.evidence(character, name: "character")
        let sheet = try await f.mount(LearnIntroSheet(turnOn: {}, notNow: {}), height: 700)
        if sheet.window?.isKeyWindow == true { #expect(f.focusedLabel(sheet) == "Not Now") }
        try f.evidence(sheet, name: "privacy-sheet")
        let strip = try await f.mount(ZeusStatusStrip(.waiting(questions: 1), onJump: {}, onSkip: {}), height: 100)
        try f.evidence(strip, name: "strip")
        for theme in f.settings.availableThemes {
            _ = try f.button(theme.name + ". " + (theme.fixedAppearance == .dark ? "Always dark" : theme.fixedAppearance == .light ? "Always light" : "Follows your Mac"), in: appearance)
        }
        for label in ["Import Theme…", "Open Example", "Open Themes Folder", "Pixel", "SF Mono", "Small text", "Default text", "Large text", "Larger text"] { _ = try f.button(label, in: appearance) }
        for label in ["Let my assistant control Zeus", "Let my assistant install updates"] {
            #expect(a12Nodes(general).contains { a12String($0, "accessibilityRole") == "AXCheckBox" && a12String($0, "accessibilityLabel") == label })
        }
        for label in ["Idle opacity", "Idle fade delay"] {
            #expect(a12Nodes(character).contains { a12String($0, "accessibilityRole") == "AXSlider" && a12String($0, "accessibilityLabel") == label })
        }
        let opacity = try #require(a12Nodes(character).first { a12String($0, "accessibilityRole") == "AXSlider" && a12String($0, "accessibilityLabel") == "Idle opacity" })
        let delay = try #require(a12Nodes(character).first { a12String($0, "accessibilityRole") == "AXSlider" && a12String($0, "accessibilityLabel") == "Idle fade delay" })
        #expect(a12String(opacity, "accessibilityValueDescription") == "30 percent")
        #expect(a12String(delay, "accessibilityValueDescription") == "30 seconds")
        // Key-view loops are native and spatially matched to AX control bounds. They can be inspected
        // beneath the lock-screen shield, unlike actual SwiftUI key activation.
        func ordered(_ labels: [String], startingAt first: String) -> [String] {
            guard let index = labels.firstIndex(of: first) else { return labels }
            return Array(labels[index...] + labels[..<index])
        }
        #expect(ordered(f.tabLabels(sheet), startingAt: "Not Now") == ["Not Now", "Turn On"])
        #expect(ordered(f.tabLabels(strip), startingAt: "Question. Waiting for your answer. Go to question") == ["Question. Waiting for your answer. Go to question", "Skip"])
        let themeLabels = f.settings.availableThemes.map { $0.name + ". " + ($0.fixedAppearance == .dark ? "Always dark" : $0.fixedAppearance == .light ? "Always light" : "Follows your Mac") }
        #expect(ordered(f.tabLabels(appearance), startingAt: themeLabels[0]) == themeLabels + ["Import Theme…", "Open Example", "Open Themes Folder", "Pixel", "SF Mono", "Small text", "Default text", "Large text", "Larger text"])
        // UX5: "Keep activity for" and the note checkboxes are disabled while Learn from me is off, so they leave the tab order.
        let privacyLabels = ["Let Zeus learn when and in what I work"]
            + f.learn.settings.excludedApps.map { "Remove \($0.name)" } + ["Add App…"]
            + (f.learn.settings.enabled ? LearnSettings.retentionChoices.map { "\($0) days" } + MomentKind.allCases.map(\.title) : [])
            + ["Delete Everything…"]
        #expect(ordered(f.tabLabels(privacy), startingAt: privacyLabels[0]) == privacyLabels)
        let generalLabels = f.tabLabels(general)
        #expect(Set(generalLabels).count == generalLabels.count && !generalLabels.contains { $0.hasPrefix("Unmatched") })
        #expect(ordered(generalLabels, startingAt: "Let my assistant control Zeus").starts(with: ["Let my assistant control Zeus", "Let my assistant install updates", "Show menu bar icon", "Launch Zeus at login"]))
        let characterLabels = f.tabLabels(character)
        #expect(!characterLabels.contains { $0.hasPrefix("Unmatched") })
        #expect(characterLabels.contains("Idle opacity") && characterLabels.contains("Idle fade delay"))
        let navigation = SettingsNavigation()
        let tabs = try await f.mount(SettingsTabBar(navigation: navigation), width: 700, height: 100)
        #expect(ordered(f.tabLabels(tabs), startingAt: "General") == navigation.tabs.map(\.rawValue))
        try f.evidence(tabs, name: "settings-tabs")
    }

    @Test func privateAppPickerAnnouncesAddedAndAlreadyPrivateButNotCancel() async throws {
        let f = try A12Fixture(); defer { f.cleanup() }
        let app = f.root.appendingPathComponent("Fixture Editor.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "invalid.zeus.fixture-editor", "CFBundleName": "Fixture Editor"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        var choice: URL? = app
        var announcements: [String] = []
        let host = try await f.mount(PrivacySettingsView(learn: f.learn, pickApp: { done in done(choice) }, announce: { announcements.append($0) }))
        func pressAdd() async throws {
            #expect((try f.button("Add App…", in: host) as AnyObject).accessibilityPerformPress?() == true)
            try await f.settle(host)
        }
        try await pressAdd()
        #expect(announcements == ["Added Fixture Editor to your private list."])
        #expect(f.learn.settings.excludedApps.filter { $0.name == "Fixture Editor" }.count == 1)
        #expect(a12Nodes(host).contains { a12String($0, "accessibilityValue") == announcements.last })
        try await pressAdd()
        #expect(announcements.last == "Fixture Editor is already on your private list.")
        #expect(f.learn.settings.excludedApps.filter { $0.name == "Fixture Editor" }.count == 1)
        choice = nil; try await pressAdd()
        #expect(announcements.count == 2)
        try f.evidence(host, name: "private-app-result")
    }

    @Test func undoAndShowNowAnnounceOnceAndReopenedResolvedLinesStayQuiet() async throws {
        let f = try A12Fixture(); defer { f.cleanup() }
        var announcements: [String] = [], actions = 0
        f.cards.recordAppChange(.init(summary: "Changed the theme", undoTitle: "Undo", undo: { actions += 1 }))
        let host = try await f.mount(A12NoticeFixture(cards: f.cards, announce: { announcements.append($0) }), height: 200)
        #expect((try f.button("Undo: Changed the theme", in: host) as AnyObject).accessibilityPerformPress?() == true)
        try await f.settle(host)
        #expect(announcements == ["Changed the theme. Undone."] && actions == 1)
        #expect(!a12Nodes(host).contains { a12String($0, "accessibilityLabel") == "Undo: Changed the theme" })
        let reopened = try await f.mount(A12NoticeFixture(cards: f.cards, announce: { announcements.append($0) }), height: 200)
        try f.evidence(reopened, name: "undone")
        #expect(announcements.count == 1)
        f.cards.recordAppChange(.init(summary: "Hid Zeus for 10 minutes", undoTitle: "Show now", undo: { actions += 1 }))
        try await f.settle(host)
        #expect((try f.button("Show now: Hid Zeus for 10 minutes", in: host) as AnyObject).accessibilityPerformPress?() == true)
        try await f.settle(host)
        // Both mounted fixtures observe the change; each announces only on its own state transition.
        #expect(actions == 2 && announcements.suffix(2).allSatisfy { $0 == "Hid Zeus for 10 minutes. Undone." })
    }

    @Test func dailySummaryViewHasContextAndReportsExpandedAndCollapsed() async throws {
        let f = try A12Fixture(); defer { f.cleanup() }
        f.cards.recordNotice(.init(kind: .learning, createdAt: Date(), summary: "Sent your daily summary", actionTitle: "View", detail: "Fixture summary text."))
        let host = try await f.mount(A12NoticeFixture(cards: f.cards, announce: { _ in }), height: 200)
        let view = try f.button("View: Sent your daily summary", in: host)
        #expect(a12String(view, "accessibilityValue") == "Collapsed")
        #expect((view as AnyObject).accessibilityPerformPress?() == true)
        try await f.settle(host)
        let hide = try f.button("Hide: Sent your daily summary", in: host)
        #expect(a12String(hide, "accessibilityValue") == "Expanded")
        #expect(a12Nodes(host).contains { a12Description($0).contains("Fixture summary text.") })
        #expect((hide as AnyObject).accessibilityPerformPress?() == true)
        try await f.settle(host)
        #expect(a12String(try f.button("View: Sent your daily summary", in: host), "accessibilityValue") == "Collapsed")
        try f.evidence(host, name: "daily-summary")
    }

    @Test func privacySheetEscapeNeverEnablesLearning() async throws {
        let f = try A12Fixture(); defer { f.cleanup() }
        var turnedOn = 0, cancelled = 0
        let host = try await f.mount(LearnIntroSheet(turnOn: { turnedOn += 1 }, notNow: { cancelled += 1 }), height: 700)
        _ = try f.button("Not Now", in: host); _ = try f.button("Turn On", in: host)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: host.window?.windowNumber ?? 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        #expect(host.window?.performKeyEquivalent(with: event) == true)
        #expect(cancelled == 1 && turnedOn == 0 && !f.learn.settings.enabled)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ZEUS_A12_LIVE_KEYS"] == "1",
                   "Requires an unlocked Mac; sends events only inside its offscreen fixture window."))
    func privacySheetKeyboardDefaultsToNotNowAndTabSpaceReturnWorkOnce() async throws {
        let f = try A12Fixture(); defer { f.cleanup() }
        var actions: [String] = []
        let host = try await f.mount(LearnIntroSheet(turnOn: { actions.append("Turn On") }, notNow: { actions.append("Not Now") }), height: 700)
        NSApp.activate(); host.window?.makeKey()
        try await f.settle(host)
        #expect(host.window?.isKeyWindow == true && NSApp.isActive, "macOS must accept the fixture as key before keyboard activation is evidence")
        func key(_ text: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: host.window?.windowNumber ?? 0, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
            NSApp.sendEvent(event)
        }
        try key("\r", code: 36, modifiers: .option)
        try await f.settle(host)
        #expect(actions.isEmpty)
        try key("\r", code: 36)
        try await f.settle(host)
        #expect(actions == ["Not Now"])
        host.window?.selectNextKeyView(nil); try await f.settle(host)
        try key(" ", code: 49); try await f.settle(host)
        #expect(actions == ["Not Now", "Turn On"])
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ZEUS_A12_LIVE_KEYS"] == "1",
                   "Requires an unlocked Mac; no global event posting or real settings."))
    func nativeKeysActivateThemeCheckboxNoticeStripAndGhostSlider() async throws {
        let f = try A12Fixture(); defer { f.cleanup() }
        func focus(_ label: String, in host: NSView) async throws {
            NSApp.activate(); host.window?.makeKey(); try await f.settle(host)
            try #require(host.window?.isKeyWindow == true && NSApp.isActive)
            for _ in 0..<60 {
                if f.focusedLabel(host) == label { return }
                host.window?.selectNextKeyView(nil)
                try await Task.sleep(for: .milliseconds(20))
            }
            Issue.record("Tab never reached \(label)")
            throw CocoaError(.coderValueNotFound)
        }
        func key(_ text: String, code: UInt16, in host: NSView) throws {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: host.window?.windowNumber ?? 0, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
            NSApp.sendEvent(event)
        }
        let appearance = try await f.mount(AppearanceSettingsView(settings: f.settings))
        try await focus("Phosphor. Always dark", in: appearance)
        try key(" ", code: 49, in: appearance); try await f.settle(appearance)
        #expect(f.settings.currentThemeID == "phosphor")
        let general = try await f.mount(GeneralSettingsView(settings: f.settings, login: LoginItemModel(), hotKey: GlobalHotKey()))
        try await focus("Let my assistant control Zeus", in: general)
        try key(" ", code: 49, in: general); try await f.settle(general)
        #expect(!f.settings.assistantMayControlApp)
        var undos = 0
        f.cards.recordAppChange(.init(summary: "Changed the theme", undoTitle: "Undo", undo: { undos += 1 }))
        let notice = try await f.mount(A12NoticeFixture(cards: f.cards, announce: { _ in }), height: 200)
        try await focus("Undo: Changed the theme", in: notice)
        try key("\r", code: 36, in: notice); try await f.settle(notice)
        #expect(undos == 1 && f.cards.notices.first?.resolvedTitle == "Undone")
        var jumps = 0, skips = 0
        let strip = try await f.mount(ZeusStatusStrip(.waiting(questions: 1), onJump: { jumps += 1 }, onSkip: { skips += 1 }), height: 100)
        try await focus("Skip", in: strip)
        try key(" ", code: 49, in: strip); try await f.settle(strip)
        #expect(skips == 1 && jumps == 0)
        f.settings.fadeZeusWhenIdle = true
        let character = try await f.mount(CharacterSettingsView(settings: f.settings, resetPosition: {}), height: 1400)
        try await focus("Idle opacity", in: character)
        let old = f.settings.idleOpacity
        try key(String(UnicodeScalar(NSRightArrowFunctionKey) ?? " "), code: 124, in: character)
        try await f.settle(character)
        #expect(f.settings.idleOpacity > old)
    }

    @Test func generalSwitchesExposeCheckedAndDisabledStatesAndPrivacyActionsKeepSafeFocus() async throws {
        let f = try A12Fixture(); defer { f.cleanup() }
        let general = try await f.mount(GeneralSettingsView(settings: f.settings, login: LoginItemModel(), hotKey: GlobalHotKey()))
        func checkbox(_ label: String) throws -> NSObject {
            try #require(a12Nodes(general).first { a12String($0, "accessibilityRole") == "AXCheckBox" && a12String($0, "accessibilityLabel") == label })
        }
        let master = try checkbox("Let my assistant control Zeus")
        let value = master.perform(NSSelectorFromString("accessibilityValue"))?.takeUnretainedValue() as? NSNumber
        #expect(value?.boolValue == true)
        #expect((master as AnyObject).accessibilityPerformPress?() == true)
        try await f.settle(general)
        #expect(!f.settings.assistantMayControlApp)
        let updates = try checkbox("Let my assistant install updates")
        #expect((updates as AnyObject).isAccessibilityEnabled?() == false)
        #expect(!f.tabLabels(general).contains("Let my assistant install updates"))
        #expect(f.settings.assistantMayInstallUpdates, "Disabling authority keeps the user's saved update preference")

        f.learn.settings.enabled = true
        let privacy = try await f.mount(PrivacySettingsView(learn: f.learn))
        #expect((try f.button("Pause for Today", in: privacy) as AnyObject).accessibilityPerformPress?() == true)
        try await f.settle(privacy)
        #expect(f.learn.isPausedNow)
        #expect((try f.button("Resume", in: privacy) as AnyObject).accessibilityPerformPress?() == true)
        try await f.settle(privacy)
        #expect(!f.learn.isPausedNow)
        #expect((try f.button("Delete Everything…", in: privacy) as AnyObject).accessibilityPerformPress?() == true)
        try await f.settle(privacy)
        _ = try f.button("Delete", in: privacy)
        _ = try f.button("Cancel", in: privacy)
        let tabs = f.tabLabels(privacy)
        #expect(tabs.filter { $0 == "Cancel" }.count == 1 && tabs.filter { $0 == "Delete" }.count == 1)
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: privacy.window?.windowNumber ?? 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        #expect(privacy.window?.performKeyEquivalent(with: escape) == true)
        try await f.settle(privacy)
        _ = try f.button("Delete Everything…", in: privacy)
        #expect(f.learn.settings.enabled)
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func focusRingAndNamesRemainAvailableInEveryBundledTheme(scheme: ColorScheme) async throws {
        let f = try A12Fixture(); defer { f.cleanup() }
        for theme in f.settings.availableThemes {
            let host = try await f.mount(LearnIntroSheet(turnOn: {}, notNow: {})
                .background(theme.palette(for: scheme).panel)
                .environment(\.zeusTheme, theme).environment(\.colorScheme, scheme), height: 700,
                referenceColor: theme.palette(for: scheme).focusRing)
            _ = try f.button("Not Now", in: host); _ = try f.button("Turn On", in: host)
            #expect(try f.rendersFocusRing("Not Now", in: host), "\(theme.id)")
            if host.window?.isKeyWindow == true { #expect(f.focusedLabel(host) == "Not Now", "\(theme.id)") }
            try f.evidence(host, name: "focus-\(theme.id)-\(scheme == .light ? "light" : "dark")")
            #expect(f.tabLabels(host).count == 2, "\(theme.id)")
        }
    }

    @Test func managedConfirmationsFocusLaterOrKeepRunningAndEscapeKeepsTheConversation() async throws {
        let f = try A12Fixture(); defer { f.cleanup() }
        f.managed.update { $0.folder = "/fixture" }
        f.settings.managedLaunchedConfig = f.managed.config
        f.controller.managedStatus = .running(.idle)
        f.managed.chooseAgent(.codex)
        let switchHost = try await f.mount(AssistantSettingsView(settings: f.settings, managed: f.managed, messaging: f.hub,
            testMessage: ComposeModel(cards: f.cards, messaging: f.hub)), height: 1800)
        if switchHost.window?.isKeyWindow == true { #expect(f.focusedLabel(switchHost) == "Later") }
        _ = try f.button("Switch Now", in: switchHost)
        try f.evidence(switchHost, name: "switch-confirmation")
        #expect(f.tabLabels(switchHost).filter { $0 == "Later" }.count == 1)
        func escape(_ host: NSView) throws {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: host.window?.windowNumber ?? 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
            #expect(host.window?.performKeyEquivalent(with: event) == true)
        }
        try escape(switchHost); try await f.settle(switchHost)
        #expect(f.managed.confirmation == nil && f.controller.fresh == 0)
        f.managed.chooseManaged(false)
        let stopHost = try await f.mount(AssistantSettingsView(settings: f.settings, managed: f.managed, messaging: f.hub,
            testMessage: ComposeModel(cards: f.cards, messaging: f.hub)), height: 1800)
        if stopHost.window?.isKeyWindow == true { #expect(f.focusedLabel(stopHost) == "Keep Running") }
        _ = try f.button("Stop", in: stopHost)
        try f.evidence(stopHost, name: "stop-confirmation")
        try escape(stopHost); try await f.settle(stopHost)
        #expect(f.controller.managedStatus == .running(.idle) && !f.managed.enabled)
    }
}

private struct A12NoticeFixture: View {
    let cards: CardStore
    let announce: @MainActor (String) -> Void
    var body: some View {
        VStack {
            ForEach(cards.notices) { notice in
                ConversationNoticeLine(notice: notice, maxWidth: 420, hasAction: cards.hasNoticeAction(id: notice.id),
                    perform: { cards.performNoticeAction(id: notice.id) }, announce: announce)
            }
        }
    }
}
