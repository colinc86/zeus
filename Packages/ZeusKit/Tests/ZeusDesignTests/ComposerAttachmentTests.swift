import Testing
@testable import ZeusDesign

struct ComposerAttachmentTests {
    @Test func blankAndWhitespaceDraftsNeedAttachmentsAndSendingAlwaysBlocks() {
        #expect(ZeusComposer.canSend("", isSending: false, hasAttachments: true))
        #expect(!ZeusComposer.canSend("", isSending: false))
        #expect(!ZeusComposer.canSend(" \n\t", isSending: false))
        #expect(ZeusComposer.canSend(" \n", isSending: false, hasAttachments: true))
        #expect(!ZeusComposer.canSend("", isSending: true, hasAttachments: true))
    }
}
