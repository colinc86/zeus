import CoreGraphics
import Foundation

/// Where Zeus lives: one anchor per display set, plus the last anchor as the fallback for a set never seen (FX25).
/// A display change moves him onto a screen that exists but never records that move; only the user's drag, the
/// assistant's `zeus_move`, a reset or a size change record a home.
struct AvatarHomes: Equatable {
    private(set) var byDisplaySet: [String: CGPoint]
    private(set) var last: CGPoint?

    static let lastXKey = "avatar.anchor.x", lastYKey = "avatar.anchor.y", setsKey = "avatar.anchors"

    init(byDisplaySet: [String: CGPoint] = [:], last: CGPoint? = nil) {
        self.byDisplaySet = byDisplaySet
        self.last = last
    }

    init(defaults: UserDefaults) {
        var sets: [String: CGPoint] = [:]
        for (key, value) in defaults.dictionary(forKey: Self.setsKey) ?? [:] {
            guard let pair = value as? [Double], pair.count == 2, pair[0].isFinite, pair[1].isFinite else { continue }
            sets[key] = CGPoint(x: pair[0], y: pair[1])
        }
        var last: CGPoint?
        if let x = defaults.object(forKey: Self.lastXKey) as? Double, let y = defaults.object(forKey: Self.lastYKey) as? Double,
           x.isFinite, y.isFinite { last = CGPoint(x: x, y: y) }
        self.init(byDisplaySet: sets, last: last)
    }

    /// Stable for the same displays in the same arrangement, whatever order AppKit lists them in.
    static func displaySetKey(_ screens: [CGRect]) -> String {
        screens.map { "\(Int($0.minX.rounded())),\(Int($0.minY.rounded())),\(Int($0.width.rounded())),\(Int($0.height.rounded()))" }
            .sorted().joined(separator: ";")
    }

    /// The home for this display set, else the last home anywhere (to be clamped onto a screen that exists).
    func anchor(for screens: [CGRect]) -> CGPoint? { byDisplaySet[Self.displaySetKey(screens)] ?? last }

    mutating func record(_ anchor: CGPoint, screens: [CGRect]) {
        guard anchor.x.isFinite, anchor.y.isFinite else { return }
        byDisplaySet[Self.displaySetKey(screens)] = anchor
        last = anchor
        // Keep the most recent 16 arrangements; a laptop that visits many desks never grows this without bound.
        if byDisplaySet.count > 16, let drop = byDisplaySet.keys.sorted().first(where: { $0 != Self.displaySetKey(screens) }) {
            byDisplaySet.removeValue(forKey: drop)
        }
    }

    func save(to defaults: UserDefaults) {
        defaults.set(last?.x, forKey: Self.lastXKey)
        defaults.set(last?.y, forKey: Self.lastYKey)
        defaults.set(byDisplaySet.mapValues { [Double($0.x), Double($0.y)] }, forKey: Self.setsKey)
    }
}
