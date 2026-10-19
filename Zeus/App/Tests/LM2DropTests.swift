import AppKit
import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

@MainActor private final class DropMessaging: AgentMessaging {
    var sessions: [ConnectedSession] = []
    var sent: [String] = []
    var outcome: MessageSendResult = .delivered
    func sendUserMessage(_ text: String) async -> MessageSendResult { sent.append(text); return outcome }
}

@MainActor struct LM2DropTests {
    @Test func mixedDropIsRemovableAndImageIsAFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-drop-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pasteboard = NSPasteboard.withUniqueName(); defer { pasteboard.releaseGlobally() }
        let folder = NSPasteboardItem(); folder.setString(root.absoluteString, forType: .fileURL)
        let link = NSPasteboardItem(); link.setString("https://example.invalid/test", forType: .URL)
        let text = NSPasteboardItem(); text.setString("first\nsecond", forType: .string)
        let image = NSPasteboardItem(); image.setData(Data([1, 2, 3]), forType: .png)
        pasteboard.writeObjects([folder, link, text, image])
        let result = AvatarDrop.read(pasteboard, directory: root.appendingPathComponent("attachments"))
        #expect(result.error == nil)
        #expect(result.attachments.map(\.kind) == [.folder, .url, .file, .file])
        #expect(try String(contentsOfFile: result.attachments[2].target, encoding: .utf8) == "first\nsecond")
        #expect(try Data(contentsOf: URL(fileURLWithPath: result.attachments[3].target)) == Data([1, 2, 3]))
        let messaging = DropMessaging()
        let model = ConversationModel(cards: CardStore(fileURL: root.appendingPathComponent("cards.json")), messaging: messaging)
        model.attach(result.attachments)
        model.removeAttachment(id: result.attachments[1].id)
        #expect(model.draftAttachments.count == 3)
        #expect(!ConversationModel.message("", attaching: model.draftAttachments).contains("https://example.invalid"))
    }

    @Test func attachmentOnlySendIsDurableAndFailureKeepsDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-drop-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("sample file.png")
        let messaging = DropMessaging(), cards = CardStore(fileURL: root.appendingPathComponent("cards.json"))
        let model = ConversationModel(cards: cards, messaging: messaging)
        let attachment = Attachment(kind: .file, label: "Image", target: file.path)
        model.attach([attachment]); #expect(model.canSend)
        messaging.outcome = .failed(reason: "Offline")
        await model.send()
        #expect(model.draftAttachments == [attachment])
        #expect(cards.cards.first?.attachments == [attachment])
        #expect(messaging.sent.first?.contains("sample%20file.png") == true)
        messaging.outcome = .queued(reason: "Waiting")
        await model.send()
        #expect(model.draftAttachments.isEmpty)
        #expect(CardStore(fileURL: root.appendingPathComponent("cards.json")).cards.count == 2)
    }

    @Test func scopeCoinNeverOverridesPrivateListAndFutureLevelsStayOff() throws {
        let privateApp = ExcludedApp(name: "Private", bundleIDs: ["private.test"])
        var policy = ObservationPolicy()
        #expect(policy.allows(bundleID: "public.test", name: "Public", privateApps: [privateApp]))
        policy.apps = [privateApp]; policy.scope = .chosenApps
        #expect(!policy.allows(bundleID: "private.test", name: "Private", privateApps: [privateApp]))
        #expect(!policy.allows(bundleID: nil, name: "Private", privateApps: []))
        policy.apps = [.init(name: "Public", bundleIDs: ["public.test"])]
        #expect(policy.allows(bundleID: "public.test", name: nil, privateApps: [privateApp]))
        #expect(!policy.allows(bundleID: "other.test", name: nil, privateApps: []))
        let suite = TestDefaults.suite("zeus-observation-test"), defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ObservationSettings(defaults: defaults)
        #expect(!settings.policy(2).enabled)
        policy.enabled = true; settings.set(2, policy); settings.set(5, policy)
        #expect(ObservationSettings(defaults: defaults).policy(2) == policy)
        #expect(!settings.policy(5).enabled)
    }
}
