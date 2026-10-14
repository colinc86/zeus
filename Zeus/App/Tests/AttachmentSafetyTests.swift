import AppKit
import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

struct AttachmentSafetyTests {
    private func attachment(_ url: URL, kind: ZeusProtocol.Attachment.Kind = .file) -> ZeusProtocol.Attachment {
        Attachment(kind: kind, label: "Agent output", target: url.path)
    }

    @Test(arguments: ["app", "command", "terminal", "workflow", "pkg", "mpkg", "scpt", "scptd", "sh", "bash", "zsh", "fish", "py", "rb", "pl", "js", "bundle", "framework", "plugin"])
    func launchableExtensionsOnlyReveal(_ ext: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-attachment-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("Agent output.\(ext)")
        if ["app", "workflow", "scptd"].contains(ext) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } else { try Data("agent output".utf8).write(to: url) }
        #expect(AttachmentTarget.action(for: attachment(url)) == .reveal(url))
        // A bundle disguised as a folder is still never launched.
        guard case .reveal(let folderTarget)? = AttachmentTarget.action(for: attachment(url, kind: .folder)) else {
            Issue.record("A launchable attachment disguised as a folder must reveal"); return
        }
        #expect(folderTarget.path == url.path)
    }

    @Test func symlinkToApplicationAndExecutableHeaderWithDocumentExtensionOnlyReveal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-attachment-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let app = root.appendingPathComponent("Hidden.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("innocent.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: app)
        #expect(AttachmentTarget.action(for: attachment(link)) == .reveal(app))
        let disguised = root.appendingPathComponent("report.txt")
        try Data([0xCF, 0xFA, 0xED, 0xFE]).write(to: disguised)
        #expect(AttachmentTarget.action(for: attachment(disguised)) == .reveal(disguised))
        try Data("#!/bin/sh\necho should-not-run".utf8).write(to: disguised)
        #expect(AttachmentTarget.action(for: attachment(disguised)) == .reveal(disguised))
        let executable = root.appendingPathComponent("tool")
        try Data("unknown executable".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        #expect(AttachmentTarget.action(for: attachment(executable)) == .reveal(executable))
    }

    @Test func ordinaryDocumentsFoldersAndWebLinksKeepTheirExpectedActions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-attachment-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let document = root.appendingPathComponent("document with spaces.txt")
        try Data("Safe readable document".utf8).write(to: document)
        #expect(AttachmentTarget.action(for: attachment(document)) == .open(document))
        #expect(AttachmentTarget.action(for: attachment(document), reveal: true) == .reveal(document))
        guard case .open(let folder)? = AttachmentTarget.action(for: attachment(root, kind: .folder)) else {
            Issue.record("Expected ordinary folder to open"); return
        }
        #expect(folder.path == root.path)
        let web = Attachment(kind: .url, label: "Website", target: "https://example.com/report")
        #expect(AttachmentTarget.action(for: web) == .open(try #require(URL(string: web.target))))
        #expect(AttachmentTarget.action(for: Attachment(kind: .url, label: "Blocked", target: "file:///tmp/a.app")) == nil)
    }

    @MainActor @Test func avatarAccessibilityIncludesCharacterAndUnreadCount() throws {
        let suite = "zeus-ax-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-ax-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = AppSettings(defaults: defaults, userDirectory: nil)
        settings.currentCharacterID = "wisp"
        let cards = CardStore(fileURL: root.appendingPathComponent("cards.json"))
        cards.add(Card(kind: .message, body: "One")); cards.add(Card(kind: .message, body: "Two"))
        let status = AvatarStatusModel(cards: cards)
        let avatar = AvatarInteractionView(rootView: SpriteAvatarView(settings: settings, status: status,
            messaging: AgentMessagingHub(), artLayout: AvatarArtLayout(), activity: SurfaceActivity()))
        let label = try #require(avatar.accessibilityLabel())
        #expect(label.contains(settings.currentCharacter?.name ?? ""))
        #expect(label.contains("2 unread messages"))
    }
}
