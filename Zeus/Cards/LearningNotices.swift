import Foundation

extension CardStore: LearningNoticeRecording {
    @discardableResult func recordLearningNotice(_ notice: LearningNotice, action: (@MainActor () -> Void)?) -> Bool {
        let line = ThreadNotice(id: notice.id, kind: .learning, createdAt: notice.createdAt,
                                summary: notice.summary, actionTitle: notice.actionTitle, detail: action == nil ? notice.detail : nil)
        let installedAction = action.map { notice.kind == .newRule ? reviewAction($0, id: notice.id) : $0 }
        // Reconnect the closure after launch; CardStore keeps the durable ID and exact existing copy.
        if notices.contains(where: { $0.id == notice.id }) {
            guard let existing = notices.first(where: { $0.id == notice.id }) else { return false }
            if existing.summary != line.summary || existing.actionTitle != line.actionTitle || existing.detail != line.detail {
                guard updateNotice(id: notice.id, { $0.summary = line.summary; $0.actionTitle = line.actionTitle; $0.detail = line.detail; $0.resolvedTitle = nil }) else { return false }
            }
            setNoticeAction(id: notice.id, action: installedAction)
            return true
        }
        return recordNotice(line, action: installedAction)
    }
    private func reviewAction(_ action: @escaping @MainActor () -> Void, id: String) -> @MainActor () -> Void {
        { [weak self] in
            action()
            guard let self else { return }
            self.setNoticeAction(id: id, action: self.reviewAction(action, id: id))
        }
    }
}
