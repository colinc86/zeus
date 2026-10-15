import AppKit
import SwiftUI
import Testing
import ZeusDesign
@testable import Zeus

@MainActor private final class DepthTestPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
@MainActor private func depthNodes(_ root: Any) -> [NSObject] {
    var seen: Set<ObjectIdentifier> = []
    func walk(_ object: Any) -> [NSObject] {
        guard let node = object as? NSObject, seen.insert(ObjectIdentifier(node)).inserted else { return [] }
        func children(_ name: String, _ attribute: String? = nil) -> [Any] {
            let selector = NSSelectorFromString(name)
            return node.responds(to: selector) ? node.perform(selector, with: attribute)?.takeUnretainedValue() as? [Any] ?? [] : []
        }
        return [node] + (children("accessibilityChildren") + children("accessibilityAttributeValue:", "AXChildren") + ((node as? NSView)?.subviews ?? [])).flatMap(walk)
    }
    return walk(root)
}
@MainActor private func depthLabel(_ node: NSObject) -> String {
    for name in ["accessibilityLabel", "accessibilityValue", "accessibilityTitle"] {
        let selector = NSSelectorFromString(name)
        if node.responds(to: selector), let text = node.perform(selector)?.takeUnretainedValue() as? String, !text.isEmpty { return text }
    }
    return ""
}
@Suite(.serialized) @MainActor struct LM2DNativeTests {
    private func mount<V: View>(_ view: V) async throws -> (NSHostingView<AnyView>, NSWindow) {
        ZeusFonts.registerBundled()
        let host = NSHostingView(rootView: AnyView(view.environment(\.accessibilityEnabled, true).environment(\.zeusFontChoice, .system)
            .buttonStyle(ZeusButtonStyle(.secondary, size: .small))))
        let window = DepthTestPanel(contentRect: .init(x: -20000, y: -20000, width: 600, height: 420), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.ignoresMouseEvents = true; window.contentView = host; window.orderFront(nil)
        for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        return (host, window)
    }
    @Test func rawSheetHasVisibleDisclosureAndAccessibleCancelAllow() async throws {
        var cancelled = 0, allowed = 0
        let (host, window) = try await mount(RawJournalConsentSheet(level: .typed, allow: { allowed += 1 }, cancel: { cancelled += 1 }))
        defer { window.contentView = nil; window.close() }
        let nodes = depthNodes(host)
        for prefix in ["Every time it looks", "Cancel raw journal access", "Allow words when requested"] {
            let node = try #require(nodes.first { depthLabel($0).hasPrefix(prefix) })
            let frame = try #require((node as AnyObject).accessibilityFrame?())
            #expect(host.bounds.insetBy(dx: -1, dy: -1).contains(host.convert(window.convertFromScreen(frame), from: nil)))
        }
        let cancel = try #require(nodes.first { depthLabel($0) == "Cancel raw journal access" })
        #expect((cancel as AnyObject).accessibilityPerformPress?() == true)
        #expect(cancelled == 1 && allowed == 0)
        let allow = try #require(nodes.first { depthLabel($0) == "Allow words when requested" })
        #expect((allow as AnyObject).accessibilityPerformPress?() == true)
        #expect(allowed == 1)
    }
    @Test func shadowLineExposesBothIndependentActions() async throws {
        var primary = 0, secondary = 0
        let notice = ThreadNotice(kind: .learning, createdAt: Date(), summary: "I'd have sent an update", actionTitle: "OK next time?", secondaryTitle: "Not this")
        let (host, window) = try await mount(ConversationNoticeLine(notice: notice, maxWidth: 560, hasAction: true, perform: { primary += 1 }, hasSecondaryAction: true, performSecondary: { secondary += 1 }))
        defer { window.contentView = nil; window.close() }
        let nodes = depthNodes(host)
        let decline = try #require(nodes.first { depthLabel($0).hasPrefix("Not this:") })
        #expect((decline as AnyObject).accessibilityPerformPress?() == true)
        #expect(secondary == 1 && primary == 0)
        let approve = try #require(nodes.first { depthLabel($0).hasPrefix("OK next time?:") })
        #expect((approve as AnyObject).accessibilityPerformPress?() == true)
        #expect(primary == 1)
    }
    @Test func sentThumbnailOpensItsStoredPictureInADetailSheet() async throws {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let bytes = try #require(bitmap.representation(using: .jpeg, properties: [:]))
        let json = try JSONSerialization.data(withJSONObject: ["items": [["id": "fixture", "time": "2026-10-15T14:00:00Z", "kind": "screen", "text": "Synthetic covered frame", "picture": ["mimeType": "image/jpeg", "data": bytes.base64EncodedString()]]]])
        let item = JournalItem(level: .screen, kind: .sentToAssistant, payload: .init(.init(description: "Journal answer", text: String(decoding: json, as: UTF8.self))))
        let (host, window) = try await mount(JournalAnswerDetail(item: item))
        defer { if let sheet = window.attachedSheet { window.endSheet(sheet) }; window.contentView = nil; window.close() }
        let button = try #require(depthNodes(host).first { depthLabel($0) == "View the covered picture sent to your assistant" })
        #expect((button as AnyObject).accessibilityPerformPress?() == true)
        for _ in 0..<12 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        let sheet = try #require(window.attachedSheet)
        let content = try #require(sheet.contentView)
        #expect(depthNodes(content).contains { depthLabel($0) == "Picture sent to your assistant" })
    }
}
