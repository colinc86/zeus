import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

func m6OpenCodeSnapshot(_ name: String) throws -> ManagedPaneSnapshot {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    return .init(screen: try String(contentsOf: root.appendingPathComponent("TestFixtures/live/\(name).ansi"), encoding: .utf8), inputMetadata: "5|34|120|0|1")
}

struct M6OpenCodePaneTests {
    @Test func compactFooterIsReadyWithoutBrandingButDraftsRemainProtected() throws {
        let live = try m6OpenCodeSnapshot("m6-opencode-idle-not-ready")
        func input(_ screen: String, x: Int = 5) throws -> TmuxInputSnapshot {
            try #require(TmuxInputSnapshot(metadata: Data("\(x)|34|120|0|1".utf8), screen: Data(screen.utf8)))
        }
        #expect(try input(live.screen).isEmpty)
        #expect(ManagedPaneClassifier.classify(live, agent: .opencode) == .idle)
        let rows = live.screen.components(separatedBy: "\n")
        var draft = rows; draft[34] = "  ┃  Human draft"
        #expect(try !input(draft.joined(separator: "\n")).isEmpty)
        #expect(try !input(draft.joined(separator: "\n"), x: 16).isEmpty)
        #expect(try !input(live.screen.replacingOccurrences(of: "ctrl+p", with: "unknown")).isEmpty)
    }
}
