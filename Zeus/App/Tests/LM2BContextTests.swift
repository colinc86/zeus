import AppKit
import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

@MainActor private final class QuestionSource: FocusCaptureSource {
    var isTrusted = true, isSecure = false, isLocked = false
    var application: FocusApplication? = .init(pid: 42, bundleID: "test.editor", name: "Editor")
    var windowIdentity: ScreenCaptureIdentity? = .init(bundleID: "test.editor", processID: 42, windowID: 3)
    var calls = 0
    var record = FocusQuestionRecord(record: .init(title: "Review for sample@example.invalid", document: nil, address: "https://docs.example.invalid/safe"), selection: "Contact sample@example.invalid")
    var afterRead: () -> Void = {}
    func capture(_ application: FocusApplication) async throws -> FocusRecord? { record.record }
    func captureForQuestion(_ application: FocusApplication) async throws -> FocusQuestionRecord? { calls += 1; afterRead(); return record }
}
private struct ContextRedactor: Redactor {
    func redact(_ text: String) async -> Redacted<String> { .init(text.replacingOccurrences(of: "sample@example.invalid", with: "‹email›")) }
}
@MainActor private final class ContextMessaging: AgentMessaging {
    var sessions: [ConnectedSession] = []
    var sent: [String] = []
    var outcome: MessageSendResult = .delivered
    func sendUserMessage(_ text: String) async -> MessageSendResult { sent.append(text); return outcome }
}
@MainActor struct LM2BContextTests {
    private func fixture() throws -> (String, UserDefaults, URL, ObservationSettings, LearnSettings, QuestionSource) {
        let name = TestDefaults.suite("zeus-context"), defaults = try #require(UserDefaults(suiteName: name))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(URL(fileURLWithPath: name).lastPathComponent)
        return (name, defaults, root, ObservationSettings(defaults: defaults), LearnSettings(defaults: defaults), QuestionSource())
    }
    @Test func l2OnlyProducesSeparateRedactedRemovableChipsWithoutSending() async throws {
        let (name, defaults, root, settings, privacy, source) = try fixture()
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        settings.edit(2) { $0.enabled = true; $0.consented = true }
        var screenCalls = 0
        let ask = AskAboutThisModel(policies: settings, privacy: privacy, source: source, redactor: ContextRedactor(), captureScreen: { screenCalls += 1; return nil })
        let result = await ask.capture(directory: root.appendingPathComponent("attachments"))
        #expect(result.items.map(\.kind) == [.window, .selection, .page]); #expect(screenCalls == 0)
        for item in result.items where item.attachment.kind == .file {
            let text = try String(contentsOfFile: item.attachment.target, encoding: .utf8)
            #expect(!text.contains("sample@example.invalid")); #expect(text.contains("‹email›"))
            let attrs = try FileManager.default.attributesOfItem(atPath: item.attachment.target)
            #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
        let messaging = ContextMessaging(), cards = CardStore(fileURL: root.appendingPathComponent("cards.json"))
        let conversation = ConversationModel(cards: cards, messaging: messaging)
        conversation.attachContext(result); #expect(messaging.sent.isEmpty); #expect(conversation.canSend)
        let selection = try #require(result.items.first { $0.kind == .selection })
        conversation.removeAttachment(id: selection.id)
        #expect(!FileManager.default.fileExists(atPath: selection.attachment.target))
        messaging.outcome = .failed(reason: "Fixture offline"); await conversation.send()
        #expect(conversation.contextItems.count == 2); #expect(conversation.draftAttachments.count == 2)
        messaging.outcome = .queued(reason: "Fixture queued"); await conversation.send()
        #expect(conversation.contextItems.isEmpty); #expect(conversation.contextCaption == nil)
        #expect(cards.cards.allSatisfy { !$0.attachments.contains { $0.id == selection.id } })
    }
    @Test func offPrivatePausedAndChangedContextNeverReadOrRetainForbiddenContent() async throws {
        let (name, defaults, root, settings, privacy, source) = try fixture()
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        let ask = AskAboutThisModel(policies: settings, privacy: privacy, source: source, redactor: ContextRedactor())
        #expect(await ask.capture(directory: root).caption == ContextDraftResult.unavailable)
        #expect(source.calls == 0)
        settings.edit(2) { $0.enabled = true; $0.consented = true }
        source.isSecure = true; #expect(await ask.capture(directory: root).items.isEmpty); #expect(source.calls == 0)
        source.isSecure = false; privacy.excludedApps.append(.init(name: "Editor", bundleIDs: ["test.editor"]))
        #expect(await ask.capture(directory: root).items.isEmpty); #expect(source.calls == 0)
        privacy.excludedApps.removeAll()
        source.afterRead = { source.application = nil }
        #expect(await ask.capture(directory: root).items.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
    @Test func switchingWindowsInsideOneAppInvalidatesTheWholeExplicitCapture() async throws {
        let (name, defaults, root, settings, privacy, source) = try fixture()
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        settings.edit(2) { $0.enabled = true; $0.consented = true }
        let ask = AskAboutThisModel(policies: settings, privacy: privacy, source: source, redactor: ContextRedactor())
        source.afterRead = { source.windowIdentity = .init(bundleID: "test.editor", processID: 42, windowID: 4) }
        #expect(await ask.capture(directory: root).items.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
    @Test func screenOnlyAttachesCoveredBytesAndIdentityMismatchCannotAttachAnotherApp() async throws {
        let (name, defaults, root, settings, privacy, source) = try fixture()
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        settings.edit(3) { $0.enabled = true; $0.consented = true }
        let frame = Redacted(FrameItem(heic: Data([1, 2, 3]), width: 100, height: 60, boxes: [], appName: "Editor", windowTitle: "Covered fixture"))
        var wrong = false
        let ask = AskAboutThisModel(policies: settings, privacy: privacy, source: source, redactor: ContextRedactor(), captureScreen: {
            .init(identity: .init(bundleID: wrong ? "other.app" : "test.editor", processID: 42, windowID: 3), time: Date(), frameID: "f", descriptionID: nil, frame: frame, description: nil)
        })
        let result = await ask.capture(directory: root)
        #expect(result.items.map(\.kind) == [.picture]); #expect(source.calls == 0)
        #expect(try Data(contentsOf: URL(fileURLWithPath: result.items[0].attachment.target)) == frame.value.heic)
        wrong = true; #expect(await ask.capture(directory: root).items.isEmpty)
    }
    @Test func menuAlwaysOffersContextAfterTalkButOffShortcutHasNoEquivalent() throws {
        let name = TestDefaults.suite("zeus-context-menu"), defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults, userDirectory: nil)
        var key = settings.talkHotKey; key.enabled = false; settings.talkHotKey = key
        let shell = ShellController(defaults: defaults, cards: CardStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(URL(fileURLWithPath: name).lastPathComponent).appendingPathComponent("cards.json")), settings: settings)
        let section = try #require(shell.menuModel.sections.first { $0.contains { $0.id == "talk" } })
        #expect(section.prefix(2).map(\.id) == ["talk", "askAboutThis"])
        #expect(section[1].shortcut == nil)
    }
}
