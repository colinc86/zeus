import Testing
@testable import ZeusDesign

/// A4D-10: the runtime's failures in plain words. No tmux, HTTP or protocol vocabulary, whole sentences, and every
/// glyph drawable in the pixel font.
struct ZeusRuntimeCopyTests {
    typealias D = ZeusRuntimeCopy.Delivery
    typealias M = ZeusRuntimeCopy.Managed
    typealias O = ZeusRuntimeCopy.OpenCode

    static let sentences: [String] = [
        D.missingTmux, D.missingPane, D.couldNotPrepare, D.terminalTimedOut, D.terminalFailed, D.terminalBusy,
        D.terminalTooSmall, D.terminalChanged, D.terminalNotFound, D.terminalOtherServer,
        D.openCodeInvalidURL, D.openCodeInvalidUsername, D.openCodePasswordRejected, D.openCodeConversationNotFound,
        D.openCodeUnconfirmed, D.openCodeStatus(503), D.openCodeChooseAgain, D.openCodeSelectionOnOtherServer,
        D.openCodePinnedToOtherServer("127.0.0.1:4096"), D.openCodeUnknownServer, D.openCodeOtherFolder,
        D.disconnected, D.linkTimedOut, D.linkFailed,
        O.chooseAgainNotice, O.otherServerNotice("127.0.0.1:4096"), O.notConnected,
        M.invalidState, M.missingBridge, M.ownershipChanged, M.nameTaken, M.ambiguousConversation,
        M.conversationStoreUnreadable, M.terminalFailed, M.terminalNotReady, M.terminalAppMissing, M.cantResume(agent: "Codex"),
    ]

    /// The words the Round 4 audit found in captions: they describe Zeus's plumbing, not what the user can do.
    // "HTTP " with a space, so the "http://" a URL needs is allowed.
    static let jargon = ["exited with status", "HTTP ", "native", "NDJSON", "bridge", "zeus-mcp", "subprocess",
                         "basic-auth", "destination", "managed", "owned by", "errno", "socket", "session operation"]

    @Test func everyLineIsAWholePlainSentence() {
        for line in Self.sentences {
            #expect(line.hasSuffix("."), "\(line)")
            #expect(line.first?.isUppercase == true, "\(line)")
            #expect(!line.contains("’"), "Straight apostrophes: \(line)")
            for word in Self.jargon { #expect(!line.lowercased().contains(word.lowercased()), "\(word) in \(line)") }
        }
    }

    @Test func httpStatusesSayWhatToDo() {
        #expect(D.openCodeStatus(401) == D.openCodePasswordRejected)
        #expect(D.openCodeStatus(403) == D.openCodePasswordRejected)
        #expect(D.openCodeStatus(404) == D.openCodeConversationNotFound)
        #expect(D.openCodeStatus(500) == "OpenCode had a problem (error 500). Zeus will try again.")
    }

    /// A4D-11: Settings notices never send the user to Settings, and call it a conversation like the picker does.
    @Test func openCodeSettingsCopyMatchesThePicker() {
        for line in [O.chooseAgainNotice, O.otherServerNotice("127.0.0.1:4096"), O.choosePlaceholder] {
            #expect(!line.contains("Settings"), "\(line)")
            #expect(!line.localizedCaseInsensitiveContains("session"), "\(line)")
        }
        #expect(O.otherServerNotice("127.0.0.1:4096").contains("(127.0.0.1:4096)"))
        #expect(D.openCodePinnedToOtherServer("127.0.0.1:4096").contains("discard"))
    }

    /// A4D-6: the can't-resume state points at a new conversation, not at Try Again.
    @Test func cantResumeNamesTheRealFix() {
        #expect(M.cantResume(agent: "Codex").hasPrefix("Codex stopped before"))
        #expect(M.cantResume(agent: "Codex").hasSuffix("Start a new conversation."))
        #expect(!M.cantResumeTitle.contains("keep it running"))
    }

    @Test func pixelFontCoversEveryLine() {
        for line in Self.sentences + [M.cantResumeTitle, O.choosePlaceholder] {
            #expect(ZeusFonts.pixelFontMissingGlyphs(in: line).isEmpty, "\(line)")
        }
    }
}
