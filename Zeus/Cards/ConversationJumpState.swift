import Foundation

/// A navigation snapshot, independent of view geometry and reading side effects.
struct ConversationJumpState: Equatable {
    enum Direction: Equatable { case up, down }
    var unreadAbove: [String] = []
    var newBelow = 0
    var showsLatest = false
    var questionID: String?
    var questionDirection: Direction?
    var questionCount = 0

    static func make(entries: [ConversationEntry], visible: Set<String>, seen: Set<String>,
                     questions: [String], after lastQuestion: String? = nil,
                     atBottom: Bool, pending: Bool, awayFromLatest: Bool) -> Self {
        guard !entries.isEmpty else { return Self() }
        var result = Self()
        result.showsLatest = !atBottom && (pending || awayFromLatest)
        // No positional guesses while the lazy thread is opening or changing pages.
        guard let first = entries.firstIndex(where: { visible.contains($0.id) }),
              let last = entries.lastIndex(where: { visible.contains($0.id) }) else { return result }
        for (index, entry) in entries.enumerated() where !entry.isUser && !entry.isNotice && !entry.isRatingHeld && !seen.contains(entry.sourceCardID) {
            if index < first { result.unreadAbove.append(entry.sourceCardID) }
            if index > last { result.newBelow += 1 }
        }
        result.showsLatest = !atBottom && (result.showsLatest || result.newBelow > 0)
        let offscreen = questions.filter { !visible.contains("card:\($0)") }
        result.questionCount = questions.count
        if !offscreen.isEmpty,
           let id = nextQuestion(questions: questions, visible: visible, after: lastQuestion),
           let index = entries.firstIndex(where: { $0.id == "card:\(id)" }) {
            result.questionID = id
            result.questionDirection = index < first ? .up : .down
        }
        return result
    }

    /// Cycle chronologically, preferring offscreen questions; the strip can still focus a visible one.
    static func nextQuestion(questions: [String], visible: Set<String>, after id: String?) -> String? {
        guard !questions.isEmpty else { return nil }
        let start = id.flatMap { questions.firstIndex(of: $0) }.map { ($0 + 1) % questions.count } ?? 0
        let ordered = Array(questions[start...]) + Array(questions[..<start])
        return ordered.first { !visible.contains("card:\($0)") } ?? ordered.first
    }

    static func awayFromLatest(viewport: ConversationViewport, newestMessageTop: CGFloat?) -> Bool {
        guard viewport.height > 0 else { return false }
        let target = ConversationAutoScroll.targetOffset(viewport: viewport, newestMessageTop: newestMessageTop, pinned: true)
        return target - viewport.offset > viewport.height
    }
}
