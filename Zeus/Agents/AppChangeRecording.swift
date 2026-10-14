import Foundation

/// Optional dispatch capability until `recordAppChange` becomes a CardStoring
/// requirement. Keeps app and runtime branches source-compatible with older stores.
@MainActor
protocol AppChangeRecording: CardStoring {
    func recordAppChange(_ change: AppChange)
}
