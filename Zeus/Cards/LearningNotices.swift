import Foundation

extension CardStore: LearningNoticeRecording {
    @discardableResult func recordLearningNotice(_ notice: LearningNotice, action: (@MainActor () -> Void)?) -> Bool {
        recordLearningNotice(notice, action: action, secondaryTitle: nil, secondary: nil)
    }
    @discardableResult func recordLearningNotice(_ notice: LearningNotice, action: (@MainActor () -> Void)?,
                                                 secondaryTitle: String?, secondary: (@MainActor () -> Void)?) -> Bool {
        let line = ThreadNotice(id: notice.id, kind: .learning, createdAt: notice.createdAt,
                                summary: notice.summary, actionTitle: notice.actionTitle, detail: action == nil && notice.detail?.hasPrefix("Your rule: ") != true ? notice.detail : nil, secondaryTitle: secondaryTitle, help: notice.detail?.hasPrefix("Your rule: ") == true ? notice.detail : nil, deliveryKindName: notice.deliveryKindName)
        let installedAction = action.map { ["Review", "View"].contains(notice.actionTitle ?? "") ? reviewAction($0, id: notice.id) : $0 }
        // Reconnect the closure after launch; CardStore keeps the durable ID and exact existing copy.
        if notices.contains(where: { $0.id == notice.id }) {
            guard let existing = notices.first(where: { $0.id == notice.id }) else { return false }
            if existing.summary != line.summary || existing.actionTitle != line.actionTitle || existing.detail != line.detail || existing.secondaryTitle != secondaryTitle || existing.help != line.help || existing.deliveryKindName != line.deliveryKindName {
                guard updateNotice(id: notice.id, { $0.summary = line.summary; $0.actionTitle = line.actionTitle; $0.detail = line.detail; $0.resolvedTitle = nil; $0.secondaryTitle = secondaryTitle; $0.help = line.help; $0.deliveryKindName = line.deliveryKindName }) else { return false }
            }
            setNoticeAction(id: notice.id, action: installedAction)
            setSecondaryNoticeAction(id: notice.id, action: secondary)
            return true
        }
        guard recordNotice(line, action: installedAction) else { return false }
        setSecondaryNoticeAction(id: notice.id, action: secondary)
        return true
    }
    private func reviewAction(_ action: @escaping @MainActor () -> Void, id: String) -> @MainActor () -> Void {
        { [weak self] in
            action()
            guard let self else { return }
            self.setNoticeAction(id: id, action: self.reviewAction(action, id: id))
        }
    }
}

extension CardStore: LearningCardReadState {
    func learningCardWasRead(id: String) -> Bool { seenIDs.contains(id) }
}
