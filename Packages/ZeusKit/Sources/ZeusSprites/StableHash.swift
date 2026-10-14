import Foundation

/// Deterministic hashing for particles, accents and shake. Swift's `Hasher` is seeded per
/// process, so it can't be used: the same `(state, time)` must render identically everywhere.
enum StableHash {
    /// FNV-1a over UTF-8.
    static func string(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in s.utf8 {
            h ^= UInt64(byte)
            h = h &* 0x0000_0100_0000_01B3
        }
        return h
    }

    /// FNV-1a over raw bytes (character file fingerprints).
    static func bytes(_ data: Data) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            h ^= UInt64(byte)
            h = h &* 0x0000_0100_0000_01B3
        }
        return h
    }

    /// The SplitMix64 finalizer.
    static func mix(_ x: UInt64) -> UInt64 {
        var z = x &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A uniform value in [0, 1) derived from a seed and integer coordinates.
    static func unit(_ seed: UInt64, _ a: Int, _ b: Int = 0, _ c: Int = 0) -> Double {
        var h = mix(seed ^ UInt64(bitPattern: Int64(a)))
        h = mix(h ^ UInt64(bitPattern: Int64(b)) &* 0x9E37_79B9)
        h = mix(h ^ UInt64(bitPattern: Int64(c)) &* 0x85EB_CA6B)
        return Double(h >> 11) / Double(UInt64(1) << 53)
    }
}
