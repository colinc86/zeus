import Foundation

/// Explicit production dependencies; tests inject private roots and keys instead of ever accessing the real Keychain.
@MainActor struct LearningServices {
    let journal: any JournalStore
    let rules: any RulesStore
    let redactor: any Redactor
    let source: any FocusCaptureSource

    static func production() throws -> LearningServices {
        LearningServices(journal: EncryptedJournalStore(), rules: try PersistentRulesStore(),
                         redactor: LocalRedactor(), source: MacFocusCaptureSource())
    }
}
