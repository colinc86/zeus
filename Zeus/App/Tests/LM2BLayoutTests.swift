import AppKit
import SwiftUI
import Testing
import ZeusDesign
import ZeusProtocol
@testable import Zeus

@MainActor private final class LM2BLayoutPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
@MainActor private func lm2bNodes(_ root: Any) -> [NSObject] {
    var seen: Set<ObjectIdentifier> = []
    func walk(_ object: Any) -> [NSObject] {
        guard let node = object as? NSObject, seen.insert(ObjectIdentifier(node)).inserted else { return [] }
        func children(_ name: String, _ attribute: String? = nil) -> [Any] {
            let selector = NSSelectorFromString(name)
            return node.responds(to: selector) ? node.perform(selector, with: attribute)?.takeUnretainedValue() as? [Any] ?? [] : []
        }
        return [node] + (children("accessibilityChildren") + children("accessibilityAttributeValue:", "AXChildren") + children("accessibilityAttributeValue:", "AXContents") + ((node as? NSView)?.subviews ?? [])).flatMap(walk)
    }
    return walk(root)
}
@MainActor private func lm2bLabel(_ node: NSObject) -> String {
    for name in ["accessibilityLabel", "accessibilityValue", "accessibilityTitle"] {
        let selector = NSSelectorFromString(name)
        if node.responds(to: selector), let text = node.perform(selector)?.takeUnretainedValue() as? String, !text.isEmpty { return text }
    }
    return ""
}
@MainActor @Suite(.serialized) struct LM2BLayoutTests {
    private func mount<V: View>(_ view: V, width: CGFloat, height: CGFloat) async throws -> (NSHostingView<AnyView>, NSWindow) {
        ZeusFonts.registerBundled()
        let host = NSHostingView(rootView: AnyView(view.accessibilityElement(children: .contain).environment(\.accessibilityEnabled, true)
            .environment(\.zeusFontChoice, .system).environment(\.zeusAnimationsActive, false).buttonStyle(ZeusButtonStyle(.secondary, size: .small))))
        let window = LM2BLayoutPanel(contentRect: .init(x: -20000, y: -20000, width: width, height: height), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.ignoresMouseEvents = true; window.contentView = host; window.orderFront(nil)
        for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        return (host, window)
    }
    @Test func threeWideChipsWrapAndAllRemoveTargetsStayVisible() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-chip-layout-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ConversationModel(cards: CardStore(fileURL: root.appendingPathComponent("cards.json")), messaging: AgentMessagingHub())
        model.attach((1...3).map { .init(kind: .file, label: "A long attachment filename number \($0).swift", target: "/fixture/\($0).txt") })
        let (host, window) = try await mount(VStack(alignment: .leading) { ContextDraftAttachments(model: model) }.padding(12).frame(width: 380, height: 150, alignment: .topLeading), width: 380, height: 150)
        defer { window.contentView = nil; window.close() }
        let buttons = lm2bNodes(host).filter { lm2bLabel($0).hasPrefix("Remove A long attachment") }
        #expect(buttons.count == 3, "Fixture labels: \(lm2bNodes(host).map(lm2bLabel).filter { !$0.isEmpty })")
        for button in buttons {
            let screenFrame = try #require((button as AnyObject).accessibilityFrame?())
            let frame = host.convert(window.convertFromScreen(screenFrame), from: nil)
            #expect(host.bounds.contains(frame)); #expect(frame.height >= 20 && frame.width >= 20)
        }
    }
    @Test func directChipFlowHasAccessibleRemoveButtons() async throws {
        let item = Attachment(kind: .file, label: "AX fixture", target: "/fixture/file.txt")
        let (host, window) = try await mount(ZeusChipFlow { ZeusAttachmentChip(item, onRemove: {}) }.frame(width: 380, height: 100), width: 380, height: 100)
        defer { window.contentView = nil; window.close() }
        let nodes = lm2bNodes(host)
        #expect(nodes.contains { lm2bLabel($0) == "Remove AX fixture" }, "Direct chip nodes: \(nodes.map { "\(type(of: $0)): \(lm2bLabel($0))" })")
    }
    @Test func shortDisplayKeepsTransmissionDisclosureAndConsentButtonsVisible() async throws {
        let (host, window) = try await mount(ScreenConsentSheet(enable: {}, cancel: {}, heightLimit: 560).frame(width: 540, height: 560), width: 540, height: 560)
        defer { window.contentView = nil; window.close() }
        let nodes = lm2bNodes(host)
        for prefix in ["Descriptions go to your assistant", "Next, macOS asks", "Continue", "Not Now"] {
            let node = try #require(nodes.first { lm2bLabel($0).hasPrefix(prefix) }, "Missing \(prefix); fixture labels: \(nodes.map(lm2bLabel).filter { !$0.isEmpty })")
            let screenFrame = try #require((node as AnyObject).accessibilityFrame?())
            let frame = host.convert(window.convertFromScreen(screenFrame), from: nil)
            #expect(host.bounds.insetBy(dx: -1, dy: -1).contains(frame), "Disclosure/control must be visible without scrolling: \(prefix)")
        }
    }
}
