import Foundation

/// Immutable shipped bytes. Add a new numbered entry whenever either template changes.
/// Legacy unnumbered versions are recognized only by exact bytes, never by their text prefix.
enum ManagedTemplateHistory {
    static let version = 3
    static let versions: [Int: [String: String]] = [
        1: ["AGENTS.md": "56175691af55b093bc8ad185725e1a1f657352b443326e33308be34f2c77ceb3", "CLAUDE.md": "81a47a027007b70a982def3ec9fe7b5bb35f7355da0abcb4c5aa7aa8f285a762"],
        2: ["AGENTS.md": "bf55a97b005c55e1eea12e4951284c4475f3d44bdde21b8b875d98d2c0094ce8", "CLAUDE.md": "5193856272499b903903050ca211943e230e2fed9a9dd90a22e67a081bfab8ad"],
        3: ["AGENTS.md": "4e95b8280bd915e22aa177bf4af19f5a33d68cf8ff9e8fac6e464619a4ae5315", "CLAUDE.md": "3c557bf0fac93ad0eb19df34044cb09014bbad6e9721c8aae93741faacfda5d4"]
    ]
    static let legacyHashes: [String: Set<String>] = [
        "AGENTS.md": ["01bfba244901112c134c1a1d1772354b85d9b073c1548d952e6677e73e6bf5c1", "20061716231cc3ae7d5eb03d0911674909c5b56c240b0442ad6746803f62183d", "36f0cdbc0576fbf1176dedfbae6660533247a36db4c731b15c040aeb9d625842", "7961720227a1e1baa027e70a4bfd9f62b7eab86ebc6e77d3580a48b13d7579d8", "98e4d3c68c6f006fd6e50766157d4b8a74be44e9d943c314a8fe233d8e0f03f6"],
        "CLAUDE.md": ["336cc4fbf19beaada7ccf9986414fa91851a8d7a07dfb3ccbe800a69eed0ab49"]
    ]
}
