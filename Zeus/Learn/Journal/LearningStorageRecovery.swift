import Foundation

/// Optional capability for Privacy presentation and explicit unlock retries. Memory queues never use plaintext files.
@MainActor protocol LearningStorageRecovering: AnyObject {
    var storageWaitingForUnlock: Bool { get }
    var pendingStorageWrites: Int { get }
    func retryPendingWrites()
}

/// Fixture providers explicitly opt out of OS file protection; AES-GCM and atomic writes remain exercised.
/// Never use this conformance for a production key provider.
@MainActor protocol FixtureLearningKeyProviding: JournalKeyProviding {}
extension FixtureLearningKeyProviding {
    var requiresProtectedFiles: Bool { false }
}

@MainActor enum LearningStorageAvailability {
    static let waitingMessage = "Learning storage is locked or unavailable. New entries stay in memory until it unlocks; quitting may lose them."
    static func isUnavailable(_ error: any Error) -> Bool {
        if let error = error as? LearningStorageError, case .keyUnavailable = error { return true }
        let error = error as NSError
        if error.domain == NSPOSIXErrorDomain { return error.code == 1 || error.code == 13 }
        if error.domain == NSCocoaErrorDomain { return [257, 513].contains(error.code) }
        return false
    }
}
