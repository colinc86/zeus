import Foundation
import Observation
import ZeusDesign

/// Reveals grapheme clusters at at least 40 per second, finishing within the peek typing cap.
@MainActor
@Observable
final class TypewriterModel {
    private(set) var wasDisplayed = false
    private(set) var text = ""
    private(set) var visibleCount = 0
    @ObservationIgnored private var startedAt: Date?
    @ObservationIgnored private var startingCount = 0
    @ObservationIgnored private let clock: () -> Date

    init(clock: @escaping () -> Date = Date.init) { self.clock = clock }
    var isRevealing: Bool { visibleCount < text.count }
    func configure(text: String, animate: Bool, active: Bool = true) {
        if self.text != text {
            visibleCount = text.hasPrefix(self.text) ? min(visibleCount, text.count) : 0
            self.text = text
            startingCount = visibleCount
            startedAt = clock()
        }
        guard active else { startedAt = nil; return }
        if !animate { finish() }
        else if isRevealing && startedAt == nil { startingCount = visibleCount; startedAt = clock() }
    }
    /// Returns true when a non-whitespace character appears, for the optional blip.
    @discardableResult func tick() -> Bool {
        guard isRevealing, let startedAt else { return false }
        let old = visibleCount
        let elapsed = max(0, clock().timeIntervalSince(startedAt))
        let count = max(0, text.count - startingCount)
        let rate = max(ZeusPeekTiming.charactersPerSecond, Double(count) / ZeusPeekTiming.maxTypingDuration)
        let next = max(old, min(text.count, startingCount + Int(min(elapsed * rate, Double(count)))))
        if next != old { visibleCount = next }
        if !isRevealing { self.startedAt = nil }
        return text.dropFirst(old).prefix(visibleCount - old).contains { !$0.isWhitespace }
    }
    func markDisplayed() { if !wasDisplayed { wasDisplayed = true } }
    func finish() { if visibleCount != text.count { visibleCount = text.count }; startedAt = nil }
}
