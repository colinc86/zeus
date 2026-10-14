import Foundation
import Testing
@testable import Zeus

struct ManagedTerminalPresentationTests {
    @Test func defaultSocketAliasesDisappearAndCollisionsUseTheirExactName() {
        for directory in ["/tmp", "/private/tmp"] {
            let command = ManagedTerminalPresentation.attach(session: "zeus-2", socket: "/private/tmp/tmux-42/default", temporaryDirectory: directory, userID: 42)
            #expect(command == "tmux attach -t zeus-2")
            #expect(!command.contains("env") && !command.contains("-S"))
        }
    }
    @Test func privateAndNamedSocketsStayExplicitAndShellSafe() {
        #expect(ManagedTerminalPresentation.attach(session: "zeus", socket: "/tmp/private socket", userID: 42) == "tmux -S '/tmp/private socket' attach -t zeus")
        #expect(ManagedTerminalPresentation.attach(session: "zeus", socket: "/tmp/tmux-42/other", userID: 42) == "tmux -S /tmp/tmux-42/other attach -t zeus")
        let command = ManagedTerminalPresentation.attach(session: "zeus'quoted", socket: "/tmp/socket's path", userID: 42)
        #expect(command.contains("'\\''") && !command.contains("env -u"))
    }
    @Test func configuredTemporaryDirectoryIdentifiesItsOwnDefaultServer() {
        #expect(ManagedTerminalPresentation.attach(session: "zeus-3", socket: "/tmp/fixture-base/tmux-42/default", temporaryDirectory: "/tmp/fixture-base", userID: 42) == "tmux attach -t zeus-3")
        #expect(ManagedTerminalPresentation.attach(session: "zeus", socket: "/tmp/tmux-42/default", temporaryDirectory: "/tmp/fixture-base", userID: 42).contains("-S"))
    }
}
