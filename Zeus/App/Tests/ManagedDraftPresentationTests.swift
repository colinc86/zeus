import AppKit
import Foundation
import Observation
import SwiftUI
import Testing
import ZeusProtocol
@testable import Zeus

@MainActor @Observable private final class DraftAlertMessaging: AgentMessaging, ManagedDraftAlertControlling {
    var sessions: [ConnectedSession] = []
    var deliveryIssue: DeliveryIssue? { nil }
    var managedDraftStatusDetail: String?
    var managedDraftCancellation: ManagedDraftCancellation?
    func sendUserMessage(_ text: String) async -> MessageSendResult { .queued(reason: "Fixture") }
    func retryPendingDeliveries() {}
    func discardPendingDeliveries() {}
    func respondToDraftCancellation(id: UUID, confirmed: Bool) {}
}

@MainActor struct ManagedDraftPresentationTests {
    @Test func menuShowsTheActionableDraftStateEvenWithUnreadMessages() throws {
        let suite = TestDefaults.suite("zeus-draft-menu")
        let defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(URL(fileURLWithPath: suite).lastPathComponent)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let cards = CardStore(fileURL: root.appendingPathComponent("cards.json"))
        let settings = AppSettings(defaults: defaults, userDirectory: nil)
        let shell = ShellController(defaults: defaults, cards: cards, settings: settings)
        cards.onAdd = nil // No native panel, hotkey, sound or announcements.
        let runtime = DraftAlertMessaging()
        shell.messaging.runtime = runtime
        cards.add(Card(kind: .content, body: "An unread notice"))
        runtime.managedDraftStatusDetail = "Waiting on unsent text in Terminal"
        #expect(shell.menuStatus == "Waiting on unsent text in Terminal")
        runtime.managedDraftStatusDetail = nil
        #expect(shell.menuStatus != "Waiting on unsent text in Terminal")
    }

    @Test func nativeConfirmationKeepsMessagesOnReturnAndExplainsTerminalTextIsUntouched() {
        let alert = ShellController.makeDraftCancellationAlert(count: 3)
        #expect(alert.alertStyle == .warning && alert.messageText == "Cancel 3 queued messages?")
        #expect(alert.buttons.map(\.title) == ["Keep Messages", "Cancel 3 Messages"])
        #expect(alert.buttons[0].keyEquivalent == "\r" && alert.buttons[1].keyEquivalent.isEmpty)
        #expect(alert.informativeText.contains("won't be sent") && alert.informativeText.contains("will stay there"))
        alert.window.orderOut(nil)
    }

    /// Offscreen UI evidence; opt-in so ordinary test gates don't mount a panel.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ZEUS_P2_RENDER"] == "1"))
    func renderDraftCardAndConfirmationWithoutCapturingTheScreen() async throws {
        let suite = TestDefaults.suite("zeus-draft-render")
        let defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(URL(fileURLWithPath: suite).lastPathComponent)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let settings = AppSettings(defaults: defaults, userDirectory: nil)
        settings.typewriterEnabled = false
        let cards = CardStore(fileURL: root.appendingPathComponent("cards.json"))
        cards.add(Card(id: ZeusRuntime.managedDraftPrefix + "render", kind: .content,
            title: "Your assistant has unsent text in Terminal",
            body: "Hold this genuine draft while I decide what to ask.\n\nZeus is holding 3 messages until it's sent or cleared.",
            options: [.init(id: "open-terminal", label: "Open in Terminal", style: .primary),
                .init(id: "cancel-draft-queue", label: "Cancel queued messages", style: .secondary)], priority: .high, mood: .alert))
        let runtime = DraftAlertMessaging()
        let model = ConversationModel(cards: cards, messaging: runtime)
        let panel = ConversationPanelState(), activity = SurfaceActivity()
        panel.isVisible = true
        activity.update(suspended: false, avatar: false, conversation: true, peek: false, settings: false)
        let view = ConversationView(settings: settings, store: cards, model: model, messaging: runtime,
            status: AvatarStatusModel(cards: cards), panel: panel, activity: activity,
            openSettings: {}, copySetup: {}, resize: { _ in })
        let host = TestHostingView(rootView: view.padding(16).background(Color.white).environment(\.colorScheme, .light))
        let window = NSWindow(contentRect: CGRect(x: -24000, y: -24000, width: 400, height: 500),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        defer { window.orderOut(nil) }
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(350))
        window.setContentSize(host.fittingSize)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(350))
        try Self.write(host, name: "draft-card")
        let alert = ShellController.makeDraftCancellationAlert(count: 3)
        alert.window.appearance = NSAppearance(named: .aqua)
        alert.layout()
        alert.window.setFrameOrigin(CGPoint(x: -24000, y: -24000))
        alert.window.orderFrontRegardless()
        defer { alert.window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(100))
        let alertView = try #require(alert.window.contentView)
        try Self.write(alertView, name: "draft-confirmation")
    }

    private static func write(_ view: NSView, name: String) throws {
        let bounds = view.bounds
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = bounds.size
        view.cacheDisplay(in: bounds, to: bitmap)
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { repo.deleteLastPathComponent() }
        let out = repo.appendingPathComponent("build/p2-renders")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: out.appendingPathComponent(name + ".png"))
    }
}
