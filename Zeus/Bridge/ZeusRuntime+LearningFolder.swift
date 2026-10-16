import Foundation

extension ZeusRuntime {
    static func withLearningFiles(_ text: String, paths: [String]) -> String {
        paths.isEmpty ? text : text + "\n\nFiles: " + paths.joined(separator: ", ")
    }
    /// Use the applied managed identity while a requested folder switch is deferred.
    func syncLearningFolder() {
        guard let learningFolder else { return }
        let folder = managedController.enabled
            ? (managedController.record?.conversation?.folder ?? routing.managedSession?.folder) : nil
        learningFolder.setManagedFolder(folder.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) })
        learningFolder.setReflections((ledger?.records ?? []).compactMap { record in
            guard record.delivery.kind == .reflection, record.discardedAt == nil,
                  !record.delivery.content.isEmpty else { return nil }
            return .init(id: record.delivery.id, text: .init(record.delivery.content), time: record.delivery.createdAt)
        })
    }
}
