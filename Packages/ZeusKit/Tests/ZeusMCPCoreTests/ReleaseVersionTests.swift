import Foundation
import Testing
@testable import ZeusMCPCore

@Test func releaseVersionUsesContainingAppRatherThanCwdOrAHardcodedRelease() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let contents = root.appendingPathComponent("Zeus.app/Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "7.8.9"], format: .xml, options: 0)
    try data.write(to: contents.appendingPathComponent("Info.plist"))
    let executable = contents.appendingPathComponent("MacOS/zeus-mcp")
    #expect(MCPReleaseVersion.resolve(executableURL: executable) == "7.8.9")
    #expect(MCPReleaseVersion.resolve(executableURL: root.appendingPathComponent("zeus-mcp")) == "development")
    #expect(MCPConfiguration(version: "test-override").version == "test-override")
    try Data("not a plist".utf8).write(to: contents.appendingPathComponent("Info.plist"))
    #expect(MCPReleaseVersion.resolve(executableURL: executable) == "development")
}
