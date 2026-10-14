// swift-tools-version: 6.2
import PackageDescription

// Owned by the PM. Owners may edit their own target's entry and must call it out in their hand-back.
let package = Package(
    name: "ZeusKit",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "ZeusProtocol", targets: ["ZeusProtocol"]),
        .library(name: "ZeusLink", targets: ["ZeusLink"]),
        .library(name: "ZeusMCPCore", targets: ["ZeusMCPCore"]),
        .executable(name: "zeus-mcp", targets: ["zeus-mcp"]),
        .library(name: "ZeusSprites", targets: ["ZeusSprites"]),
        .library(name: "ZeusDesign", targets: ["ZeusDesign"]),
        .executable(name: "zeus-sprites", targets: ["zeus-sprites"]),
    ],
    targets: [
        // platform
        .target(name: "ZeusProtocol"),
        .target(name: "ZeusLink", dependencies: ["ZeusProtocol"]),
        .testTarget(name: "ZeusProtocolTests", dependencies: ["ZeusProtocol"]),
        .testTarget(name: "ZeusLinkTests", dependencies: ["ZeusLink"]),
        .target(name: "ZeusMCPCore", dependencies: ["ZeusProtocol", "ZeusLink"]),
        .executableTarget(name: "zeus-mcp", dependencies: ["ZeusMCPCore"]),
        .testTarget(name: "ZeusMCPCoreTests", dependencies: ["ZeusMCPCore", "ZeusLink"]),

        // designer
        .target(name: "ZeusSprites", dependencies: ["ZeusProtocol"], resources: [.copy("Characters")]),
        .target(name: "ZeusDesign", dependencies: ["ZeusProtocol"], resources: [.copy("Fonts"), .copy("Themes")]),
        .executableTarget(name: "zeus-sprites", dependencies: ["ZeusSprites", "ZeusDesign", "ZeusProtocol"]),
        .testTarget(name: "ZeusSpritesTests", dependencies: ["ZeusSprites", "ZeusProtocol"]),
        .testTarget(name: "ZeusDesignTests", dependencies: ["ZeusDesign", "ZeusProtocol"]),
    ]
)
