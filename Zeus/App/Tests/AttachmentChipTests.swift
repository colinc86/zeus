import AppKit
import SwiftUI
import Testing
import ZeusDesign
import ZeusProtocol
@testable import Zeus

@MainActor private func at1Nodes(_ root: Any) -> [NSObject] {
    var seen: Set<ObjectIdentifier> = []
    func walk(_ value: Any) -> [NSObject] {
        guard let node = value as? NSObject, seen.insert(ObjectIdentifier(node)).inserted else { return [] }
        let selector = NSSelectorFromString("accessibilityChildren")
        let children = node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() as? [Any] ?? [] : []
        return [node] + (children + ((node as? NSView)?.subviews ?? [])).flatMap(walk)
    }
    return walk(root)
}
@MainActor private func at1Label(_ node: NSObject) -> String { (node as AnyObject).accessibilityLabel?() ?? "" }
@MainActor private final class AT1Panel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
@MainActor private final class AT1Press {
    let up: NSEvent
    init(_ up: NSEvent) { self.up = up }
    func release() { NSApp.postEvent(up, atStart: false) }
}

@MainActor @Suite(.serialized) struct AttachmentChipTests {
    private let synopsis = "The draft compares the two release plans. It recommends the smaller rollout because it keeps recovery simple. Review the trade-offs before approving the launch."
    @Test func missingFileAndLegacySummaryStayHonest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("at1-target-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let attachment = Attachment(kind: .file, label: "Report.md", target: root.appendingPathComponent("missing/nested/report.md").path)
        #expect(AttachmentChip.isMissing(attachment))
        #expect(AttachmentChip.revealTarget(attachment) == root.resolvingSymlinksInPath())
        #expect(AttachmentChip.accessibilityLabel(attachment) == "File: Report.md, Not found")
        var withSummary = attachment; withSummary.summary = synopsis
        #expect(AttachmentChip.accessibilityLabel(withSummary) == "File: Report.md, " + synopsis + ", Not found")
        let web = Attachment(kind: .url, label: "Plan", target: "https://example.com/plan", summary: " ")
        #expect(!AttachmentChip.isMissing(web) && AttachmentChip.revealTarget(web) == nil)
        #expect(AttachmentChip.accessibilityLabel(web) == "Link: Plan")
    }
    @Test func summaryExpandsAndActionsRemainSeparateOnAShortSurface() async throws {
        let attachment = Attachment(kind: .url, label: "Release comparison with a very long descriptive title", target: "https://example.com/plan", summary: synopsis)
        var actions: [AttachmentChip.Action] = []
        let (host, window) = try await mount(AttachmentChip(attachment: attachment, perform: { _, action in actions.append(action); return nil }), width: 240, height: 360)
        defer { window.contentView = nil; window.close() }
        let more = try #require(at1Nodes(host).first { at1Label($0) == "Show the full summary" })
        #expect((more as AnyObject).accessibilityPerformPress?() == true)
        try await settle(host)
        #expect(actions.isEmpty, "Expanding the summary must never open the attachment")
        let less = try #require(at1Nodes(host).first { at1Label($0) == "Show less" })
        let frame = try #require((less as AnyObject).accessibilityFrame?())
        #expect(host.bounds.contains(host.convert(window.convertFromScreen(frame), from: nil)))
        #expect(!at1Nodes(host).contains { at1Label($0) == "Show in Finder" }, "Web links have no Finder action")
        #expect((less as AnyObject).accessibilityPerformPress?() == true)
        try await settle(host)
        #expect(at1Nodes(host).contains { at1Label($0) == "Show the full summary" })
    }
    @Test func oneNativePressAndReturnOpenTheChipAndVoiceOverOffersReveal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("at1-press-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Fixture.md")
        try Data("Synthetic fixture".utf8).write(to: file)
        let attachment = Attachment(kind: .file, label: "Fixture.md", target: file.path, summary: "A synthetic report explains the fixture and its expected outcome.")
        var opened = 0
        var revealed = 0
        let (host, window) = try await mount(AttachmentChip(attachment: attachment, perform: { _, action in if case .open = action { opened += 1 }; if case .reveal = action { revealed += 1 }; return nil }))
        defer { window.contentView = nil; window.close() }
        let button = try #require(at1Nodes(host).first { at1Label($0) == AttachmentChip.accessibilityLabel(attachment) })
        let frame = try #require((button as AnyObject).accessibilityFrame?())
        let point = window.convertPoint(fromScreen: .init(x: frame.midX, y: frame.midY))
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 1.1, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        let release = AT1Press(up)
        let timer = Timer(timeInterval: 0.12, repeats: false) { _ in MainActor.assumeIsolated { release.release() } }
        RunLoop.main.add(timer, forMode: .common); NSApp.sendEvent(down)
        try await settle(host)
        if let event = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) {
            if event.windowNumber == window.windowNumber { NSApp.sendEvent(event) } else { NSApp.postEvent(event, atStart: true) }
        }
        #expect(opened == 1)
        window.makeKey()
        let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 2, windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        NSApp.sendEvent(enter); try await settle(host)
        #expect(opened == 2)
        let revealKey = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 3, windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        NSApp.sendEvent(revealKey); try await settle(host)
        #expect(revealed == 1 && opened == 2)
        let space = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 4, windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        NSApp.sendEvent(space); try await settle(host)
        #expect(opened == 3)

        let names = at1Nodes(host).flatMap { node -> [String] in
            let selector = NSSelectorFromString("accessibilityCustomActions")
            let actions = node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() as? [NSAccessibilityCustomAction] ?? [] : []
            return actions.map(\.name)
        }
        #expect(names.contains("Open") && names.contains("Show in Finder"))
    }
    @Test func peekKeepsSixLinesAndOnlyTheFirstAttachment() async throws {
        let attachments = (0..<12).map { Attachment(kind: .url, label: "Link \($0)", target: "https://example.com/\($0)", summary: synopsis) }
        for font in ZeusFontChoice.allCases {
            let card = Card(kind: .message, body: (1...8).map { "Line \($0)" }.joined(separator: "\n"), attachments: attachments)
            let layout = PeekLayout.measure(card: card, font: font, moreCount: 0, error: nil, answeredOptionID: nil, available: .init(width: 500, height: 500))
            #expect(layout.bodyLines == 6 && layout.showsMore)
            var two = card; two.attachments = Array(attachments.prefix(2))
            let pair = PeekLayout.measure(card: two, font: font, moreCount: 0, error: nil, answeredOptionID: nil, available: .init(width: 500, height: 500))
            #expect(layout.contentSize == pair.contentSize)
            var opened = false
            let (host, window) = try await mount(PeekContent(card: card, layout: layout, moreCount: 0, error: nil, answeredOptionID: nil, tail: nil, reveal: .full, open: { _ in opened = true }), width: layout.width, height: layout.contentSize.height + 4, font: font)
            defer { window.contentView = nil; window.close() }
            #expect(at1Nodes(host).contains { at1Label($0) == AttachmentChip.accessibilityLabel(attachments[0]) })
            #expect(!at1Nodes(host).contains { at1Label($0) == AttachmentChip.accessibilityLabel(attachments[1]) })
            let more = try #require(at1Nodes(host).first { at1Label($0) == "Show all attachments" })
            #expect((more as AnyObject).accessibilityPerformPress?() == true)
            #expect(opened)
        }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AT1_RENDER"] == "1" || ProcessInfo.processInfo.environment["TEST_RUNNER_AT1_RENDER"] == "1"))
    func attachmentFixtures() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("at1-renders-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("release-comparison-and-recovery-plan.md")
        try Data("Synthetic fixture".utf8).write(to: file)
        let attachments = [Attachment(kind: .file, label: file.lastPathComponent, target: file.path, summary: synopsis),
                           Attachment(kind: .folder, label: "Release materials", target: root.path, summary: "The folder holds the launch checklist and the rollback notes."),
                           Attachment(kind: .url, label: "Design review", target: "https://example.com/review", summary: "The review lists the final decisions and the remaining trade-offs."),
                           Attachment(kind: .file, label: "Legacy.md", target: file.path),
                           Attachment(kind: .file, label: "Moved.md", target: root.appendingPathComponent("moved.md").path, summary: "The archived notes explain why the previous plan changed.")]
        for theme in ZeusThemeLibrary.load(userDirectory: nil).themes {
            for scheme in [ColorScheme.light, .dark] {
                for font in ZeusFontChoice.allCases {
                    let name = theme.id + (scheme == .light ? "-light" : "-dark") + (font == .pixel ? "-pixel" : "-system")
                    try await render(VStack(alignment: .leading, spacing: 8) {
                        Text("The smaller rollout keeps recovery simple.").zeusFont(.body)
                        ForEach(attachments, id: \.id) { AttachmentChip(attachment: $0, previewInteraction: .rest) }
                        ZeusOptionButtons([.init(id: "approve", label: "Approve rollout")], state: .open(shortcuts: false)) { _ in }
                    }.padding(16), name: name + "-thread", theme: theme, scheme: scheme, font: font, width: 360, height: 640)
                    for (state, interaction) in [("rest", AttachmentChip.PreviewInteraction.rest), ("hover", .hover), ("focused", .focused), ("expanded", .expanded)] {
                        try await render(AttachmentChip(attachment: attachments[0], previewInteraction: interaction).padding(12), name: "at1-chip-" + state + "-" + name, theme: theme, scheme: scheme, font: font, width: 300, height: state == "expanded" ? 240 : 150)
                    }
                    for (state, index) in [("missing", 4), ("link", 2), ("legacy", 3)] {
                        try await render(AttachmentChip(attachment: attachments[index], previewInteraction: .rest).padding(12), name: "at1-chip-" + state + "-" + name, theme: theme, scheme: scheme, font: font, width: 300, height: 150)
                    }
                    let card = Card(kind: .message, title: "Release plan", body: "The smaller rollout keeps recovery simple. Review the trade-offs before approving the launch.", attachments: attachments)
                    let layout = PeekLayout.measure(card: card, font: font, moreCount: 1, error: nil, answeredOptionID: nil, available: .init(width: 500, height: 500))
                    try await render(PeekContent(card: card, layout: layout, moreCount: 1, error: nil, answeredOptionID: nil, tail: nil, reveal: .full).padding(12), name: "at1-chip-peek-" + name, theme: theme, scheme: scheme, font: font, width: layout.width + 24, height: layout.contentSize.height + 24)
                    if theme.id == "classic" {
                        try await render(VStack(alignment: .leading, spacing: 8) {
                            Text("Review the smaller rollout.").zeusFont(.body)
                            AttachmentChip(attachment: attachments[0], previewInteraction: .rest)
                            ZeusOptionButtons([.init(id: "approve", label: "Approve")], state: .open(shortcuts: false)) { _ in }
                        }.padding(12), name: "at1-chip-present-short-" + name, theme: theme, scheme: scheme, font: font, width: 240, height: 300)
                    }
                    try await render(AttachmentChip(attachment: attachments[0], compact: true).padding(12), name: name + "-peek-chip", theme: theme, scheme: scheme, font: font, width: 280, height: 120)
                }
            }
        }
    }
    private func settle(_ host: NSView) async throws {
        for _ in 0..<12 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
    }
    private func mount<V: View>(_ view: V, width: CGFloat = 360, height: CGFloat = 240, theme: ZeusThemeDefinition = .classic, scheme: ColorScheme = .dark, font: ZeusFontChoice = .pixel) async throws -> (TestHostingView, NSWindow) {
        ZeusFonts.registerBundled()
        let effective = theme.fixedAppearance ?? scheme
        let host = TestHostingView(rootView: view.frame(width: width, height: height, alignment: .topLeading)
            .environment(\.zeusTheme, theme).environment(\.zeusFontChoice, font).environment(\.colorScheme, effective)
            .environment(\.accessibilityEnabled, true).background(theme.palette(for: effective).panel).zeusThemeAppearance(theme))
        let window = AT1Panel(contentRect: .init(x: -20000, y: -20000, width: width, height: height), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.animationBehavior = .none; window.contentView = host; window.orderFront(nil)
        try await settle(host); return (host, window)
    }
    private func render<V: View>(_ view: V, name: String, theme: ZeusThemeDefinition, scheme: ColorScheme, font: ZeusFontChoice, width: CGFloat, height: CGFloat) async throws {
        let (host, window) = try await mount(view, width: width, height: height, theme: theme, scheme: scheme, font: font)
        defer { window.contentView = nil; window.close() }
        var root = URL(fileURLWithPath: #filePath); for _ in 0..<4 { root.deleteLastPathComponent() }
        let output = root.appendingPathComponent("build/at1-renders")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * 2), pixelsHigh: Int(height * 2), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = .init(width: width, height: height); host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
    }
}
