import Foundation
import ZeusProtocol

/// Explicit production dependencies; tests inject private roots and keys instead of ever accessing the real Keychain.
@MainActor struct LearningServices {
    let journal: any JournalStore
    let rules: any RulesStore
    let redactor: any Redactor
    let source: any FocusCaptureSource
    var folder: (any LearningFolderProviding)? = nil

    static func production() throws -> LearningServices {
        let journal = EncryptedJournalStore(), rules = try PersistentRulesStore(), redactor = LocalRedactor()
        // The shell installs the current consent policy before the runtime starts this shared writer.
        let folder = LearningFolderWriter(journal: journal, rules: rules,
            stateURL: ZeusPaths.appSupport.appendingPathComponent("LearningFolder.json"), enabledLevels: { [] }, redactor: redactor)
        return LearningServices(journal: journal, rules: rules, redactor: redactor, source: MacFocusCaptureSource(), folder: folder)
    }
}
