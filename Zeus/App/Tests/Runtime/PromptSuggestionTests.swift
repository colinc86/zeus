import Foundation
import Testing
@testable import Zeus

struct PromptSuggestionTests {
    @Test(arguments: ["dark", "light"])
    func realClaudeGhostIsEmptyButAcceptedOrMixedInputIsNot(theme: String) throws {
        struct Frame: Decodable { let screen: String; let inputMetadata: String }
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let frame = try JSONDecoder().decode(Frame.self, from: Data(contentsOf: root.appendingPathComponent("TestFixtures/panes/m8/claude-ghost-\(theme).json")))
        func input(_ screen: String, x: Int = 2) throws -> TmuxInputSnapshot {
            let metadata = frame.inputMetadata.components(separatedBy: "|")
            guard metadata.count == 5, let input = TmuxInputSnapshot(metadata: Data("\(x)|\(metadata[1])|120|0|0".utf8), screen: Data(screen.utf8)) else {
                throw ManagedSessionError.command("Invalid prompt-suggestion fixture")
            }
            return input
        }
        #expect(try input(frame.screen).isEmpty)
        #expect(try !input(frame.screen, x: 3).isEmpty)
        #expect(try !input(frame.screen.replacingOccurrences(of: "\u{1b}[0;2massistant arm", with: "\u{1b}[0massistant arm")).isEmpty)
        #expect(try !input(frame.screen.replacingOccurrences(of: "\u{1b}[0;2massistant arm", with: "\u{1b}[0;2massistant\u{1b}[0m arm")).isEmpty)
        #expect(try !input(frame.screen.replacingOccurrences(of: "\u{1b}[0;2massistant arm", with: "\u{1b}[0m")).isEmpty, "A one-glyph typed draft under the caret is not a ghost")
    }
    @Test(arguments: ["\u{1b}[2m", "\u{1b}[90m", "\u{1b}[38;5;246m", "\u{1b}[38;2;128;128;128m"])
    func mutedPlaceholdersDoNotDependOnTheirWording(style: String) throws {
        func snapshot(_ screen: String, x: Int, y: Int) throws -> TmuxInputSnapshot {
            try #require(TmuxInputSnapshot(metadata: Data("\(x)|\(y)|120|0|1".utf8), screen: Data(screen.utf8)))
        }
        let codex = "› \(style)A new CLI-generated suggestion\u{1b}[0m\n\narbitrary footer"
        #expect(try snapshot(codex, x: 2, y: 0).isEmpty)
        #expect(try !snapshot(codex.replacingOccurrences(of: style, with: ""), x: 2, y: 0).isEmpty)
        #expect(try !snapshot(codex.replacingOccurrences(of: "\n\n", with: "\n  Human continuation\n\n"), x: 2, y: 0).isEmpty)
        let openCode = "  ┃\n  ┃  \(style)Ask anything you like\u{1b}[0m\n  ┃\n  ┃  Build · Local fixture\n  ╹━━━━\nctrl+p commands"
        #expect(try snapshot(openCode, x: 5, y: 1).isEmpty)
        #expect(try !snapshot(openCode.replacingOccurrences(of: style, with: ""), x: 5, y: 1).isEmpty)
        #expect(try !snapshot(openCode.replacingOccurrences(of: "\n  ┃\n  ┃  Build", with: "\n  ┃  Human continuation\n  ┃  Build"), x: 5, y: 1).isEmpty)
    }
    @Test func colourParametersAndPartialGreyDoNotEraseHumanText() throws {
        for body in ["\u{1b}[38;2;255;2;255mTyped draft", "\u{1b}[38;2;128;128;128mGhost\u{1b}[39m typed", "\u{1b}[48;2;128;128;128mTyped draft"] {
            let input = try #require(TmuxInputSnapshot(metadata: Data("2|0|120|0|1".utf8), screen: Data("› \(body)\n\nfooter".utf8)))
            #expect(!input.isEmpty)
        }
    }
}
