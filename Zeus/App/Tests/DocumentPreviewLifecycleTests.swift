import AppKit
import Quartz
import SwiftUI
import Testing
import ZeusProtocol
@testable import Zeus

@MainActor @Suite(.serialized) struct DocumentPreviewLifecycleTests {
    enum Stage: CaseIterable { case beforeMount, loading, settled }

    @Test(arguments: Stage.allCases)
    func quickLookTeardownIsIdempotent(stage: Stage) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-preview-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Preview.rtf")
        try "{\\rtf1 Synthetic preview.}".write(to: url, atomically: true, encoding: .utf8)
        let view = try #require(DocumentQuickLookView(frame: .init(x: 0, y: 0, width: 320, height: 400), style: .compact))
        view.shouldCloseWithWindow = false
        let window = window()
        defer { window.contentView = nil; window.close() }
        if stage != .beforeMount {
            window.contentView = view; window.orderFront(nil)
            view.previewItem = url as NSURL
        }
        if stage == .settled { try await Task.sleep(for: .milliseconds(600)) }
        // Quick Look asserts on a second close. Both teardown owners must be safe,
        // including when dismantle follows a native close or a window detachment.
        view.close()
        window.contentView = nil
        DocumentQuickLookHost.dismantleNSView(view, coordinator: .init())
        DocumentQuickLookHost.dismantleNSView(view, coordinator: .init())
        #expect(view.isClosed && view.previewItem == nil)
    }

    @Test(arguments: [false, true], [0, 30, 600])
    func realViewerBackAndStepDuringPreview(step: Bool, milliseconds: Int) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-preview-navigation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Preview.rtf"), next = root.appendingPathComponent("Next.txt")
        try "{\\rtf1 Synthetic preview.}".write(to: url, atomically: true, encoding: .utf8)
        try "Next document".write(to: next, atomically: true, encoding: .utf8)
        let attachment = Attachment(kind: .file, label: "Preview", target: url.path)
        let sibling = Attachment(kind: .file, label: "Next", target: next.path)
        let model = DocumentViewerModel()
        let conversation = ConversationModel(cards: CardStore(fileURL: root.appendingPathComponent("cards.json")), messaging: PreviewMessaging())
        let host = TestHostingView(rootView: DocumentViewerView(model: model, conversation: conversation, back: { _ = model.back() }, context: {}))
        let window = window()
        defer { model.close(); window.contentView = nil; window.close() }
        window.contentView = host; window.orderFront(nil)
        #expect(model.open(attachment, siblings: [attachment, sibling]))
        func preview(_ view: NSView) -> DocumentQuickLookView? {
            if let value = view as? DocumentQuickLookView { return value }
            return view.subviews.lazy.compactMap(preview).first
        }
        let deadline = Date().addingTimeInterval(3)
        while preview(host) == nil && Date() < deadline {
            host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10))
        }
        let native = try #require(preview(host))
        #expect(model.current?.content?.renderer == .quickLook)
        if milliseconds > 0 { try await Task.sleep(for: .milliseconds(milliseconds)) }
        if step { #expect(model.step(1)) } else { #expect(model.back()) }
        let closedDeadline = Date().addingTimeInterval(3)
        while !native.isClosed && Date() < closedDeadline {
            host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10))
        }
        #expect(native.isClosed && native.previewItem == nil)
        #expect(step ? model.current?.url == next : !model.isOpen)
    }

    private func window() -> NSPanel {
        let window = NSPanel(contentRect: .init(x: -20000, y: -20000, width: 380, height: 500), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.animationBehavior = .none
        return window
    }
}

@MainActor private final class PreviewMessaging: AgentMessaging {
    var sessions: [ConnectedSession] = []
    func sendUserMessage(_ text: String) async -> MessageSendResult { .delivered }
}
