import AppKit
import Testing
import ZeusDesign
@testable import Zeus

@MainActor struct DocumentInteractionTests {
    @Test func readingSizeDoesNotChangeChatPreferenceAndFitsShortScreens() {
        #expect(DocumentPanelGeometry.width(chat: 380, expanded: false, screen: 1600) == 380)
        #expect(DocumentPanelGeometry.width(chat: 380, expanded: true, screen: 1600) == 760)
        #expect(DocumentPanelGeometry.width(chat: 500, expanded: true, screen: 1200) == 600)
        let height = DocumentPanelGeometry.contentHeight(composer: 100, strip: 24, screen: 240, expanded: true, tail: 12)
        #expect(height >= 0 && height + 100 + 24 + 54 + 12 <= 224)
        #expect(DocumentPanelGeometry.contentHeight(composer: 40, strip: 24, screen: 900, expanded: false, tail: 12) > 160)
    }
    @Test func documentCommandsLeaveWidthAndOrdinaryTypingAlone() {
        #expect(DocumentKeyboard.command(keyCode: 53, characters: "", modifiers: []) == .back)
        #expect(DocumentKeyboard.command(keyCode: 33, characters: "[", modifiers: .command) == .back)
        #expect(DocumentKeyboard.command(keyCode: 123, characters: "", modifiers: [.command, .control]) == .previous)
        #expect(DocumentKeyboard.command(keyCode: 124, characters: "", modifiers: [.command, .control]) == .next)
        #expect(DocumentKeyboard.command(keyCode: 123, characters: "", modifiers: [.command, .option]) == nil)
        #expect(DocumentKeyboard.command(keyCode: 3, characters: "f", modifiers: .command) == .find)
        #expect(DocumentKeyboard.command(keyCode: 3, characters: "f", modifiers: [.command, .control]) == .expand)
        #expect(DocumentKeyboard.command(keyCode: 39, characters: "\"", modifiers: [.command, .shift]) == .quote)
        #expect(DocumentKeyboard.command(keyCode: 3, characters: "f", modifiers: []) == nil)
    }
    @Test func nativePanelKeyDispatchBackFindOpenAndRevealUseDocumentTargets() async throws {
        let suite = TestDefaults.suite("zeus-dv1-keys")
        let defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(URL(fileURLWithPath: suite).lastPathComponent)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("keys.txt"); try "Find this passage".write(to: url, atomically: true, encoding: .utf8)
        let settings = AppSettings(defaults: defaults, userDirectory: nil, passwordStore: DocumentNoCredentials())
        let shell = ShellController(defaults: defaults, cards: CardStore(fileURL: root.appendingPathComponent("cards.json")), settings: settings)
        defer { shell.cardPanelState.document.close(); shell.stop(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let viewer = shell.cardPanelState.document
        #expect(viewer.open(.init(kind: .file, label: "keys.txt", target: url.path)))
        let deadline = Date().addingTimeInterval(4)
        while viewer.loading && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        var opened: [URL] = [], revealed: [URL] = []
        viewer.openExternally = { opened.append($0.url) }; viewer.revealExternally = { revealed.append($0.url) }
        func key(_ code: UInt16, _ text: String, _ flags: NSEvent.ModifierFlags) throws -> Bool {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
            return shell.handleConversationKey(event)
        }
        #expect(try key(31, "o", .command)); #expect(opened.map(\.path) == [url.resolvingSymlinksInPath().path])
        #expect(try key(15, "r", [.command, .shift])); #expect(revealed == opened)
        #expect(try key(3, "f", .command)); #expect(viewer.findVisible)
        #expect(try key(53, "", [])); #expect(!viewer.findVisible && viewer.backRequest == 0)
        #expect(try key(33, "[", .command)); #expect(viewer.backRequest == 1 && viewer.isOpen)
        #expect(try key(3, "f", [.command, .control])); #expect(viewer.expanded)
        #expect(try !key(125, "", []), "Ordinary arrows stay with the document's native scroll view")
    }

}

@MainActor private struct DocumentNoCredentials: OpenCodePasswordStoring {
    func read() -> String? { nil }
    func save(_ password: String?) {}
}
