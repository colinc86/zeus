import Foundation

/// Pure deadline selection, shared by the shell and boundary tests.
enum LifecycleDeadline {
    static func earliest(after now: Date, candidates: [Date?]) -> Date? {
        candidates.compactMap { $0 }.filter { $0 > now }.min()
    }
}
