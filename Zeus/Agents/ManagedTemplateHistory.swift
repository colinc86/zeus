import Foundation

/// Immutable shipped bytes. Add a new numbered entry whenever either template changes.
/// Legacy unnumbered versions are recognized only by exact bytes, never by their text prefix.
enum ManagedTemplateHistory {
    static let version = 1
    static let versions: [Int: [String: String]] = [1: ["AGENTS.md": "56175691af55b093bc8ad185725e1a1f657352b443326e33308be34f2c77ceb3", "CLAUDE.md": "81a47a027007b70a982def3ec9fe7b5bb35f7355da0abcb4c5aa7aa8f285a762"]]
    static let legacyHashes: [String: Set<String>] = [
        "AGENTS.md": ["01bfba244901112c134c1a1d1772354b85d9b073c1548d952e6677e73e6bf5c1", "20061716231cc3ae7d5eb03d0911674909c5b56c240b0442ad6746803f62183d", "36f0cdbc0576fbf1176dedfbae6660533247a36db4c731b15c040aeb9d625842", "7961720227a1e1baa027e70a4bfd9f62b7eab86ebc6e77d3580a48b13d7579d8", "98e4d3c68c6f006fd6e50766157d4b8a74be44e9d943c314a8fe233d8e0f03f6"],
        "CLAUDE.md": ["336cc4fbf19beaada7ccf9986414fa91851a8d7a07dfb3ccbe800a69eed0ab49"]
    ]
}
