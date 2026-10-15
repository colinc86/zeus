import Darwin
import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

/// Builds only test fixtures under build/. No repository targets or app entry points change.
private actor RuntimeHostBuilder {
    static let shared = RuntimeHostBuilder()
    private var tasks: [String: Task<URL, any Error>] = [:]
    func executable(configuration: String) async throws -> URL {
        if let task = tasks[configuration] { return try await task.value }
        let task = Task { try await build(configuration: configuration) }
        tasks[configuration] = task
        return try await task.value
    }
    private func build(configuration: String) async throws -> URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let package = root.appendingPathComponent("build/P13Host-" + configuration)
        let sources = package.appendingPathComponent("Sources/Host")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        var inputs = [root.appendingPathComponent("TestFixtures/E2EHost/RuntimeHost.swift"),
                      root.appendingPathComponent("Zeus/Shared/AppSeams.swift"),
                      root.appendingPathComponent("Zeus/Learn/Seams.swift"),
                      root.appendingPathComponent("Zeus/Cards/AttachmentTarget.swift"),
                      root.appendingPathComponent("Zeus/Cards/CardStore.swift"),
                      root.appendingPathComponent("Zeus/Cards/ContextSendIntent.swift"),
                      root.appendingPathComponent("Zeus/Cards/ThreadNotice.swift")]
        for directory in ["Zeus/Bridge", "Zeus/Agents"] {
            inputs += try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent(directory), includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "DebugSpriteFrameCounter.swift" }
        }
        for input in inputs {
            let data = try Data(contentsOf: input), destination = sources.appendingPathComponent(input.lastPathComponent)
            if (try? Data(contentsOf: destination)) != data { try data.write(to: destination, options: .atomic) }
        }
        let manifest = """
        // swift-tools-version: 6.2
        import PackageDescription
        let package = Package(name: "P13Host", platforms: [.macOS(.v26)],
          dependencies: [.package(path: \(root.appendingPathComponent("Packages/ZeusKit").path.debugDescription))],
          targets: [.executableTarget(name: "Host", dependencies: [
            .product(name: "ZeusProtocol", package: "ZeusKit"), .product(name: "ZeusLink", package: "ZeusKit"),
            .product(name: "ZeusSprites", package: "ZeusKit"), .product(name: "ZeusDesign", package: "ZeusKit")])])
        """
        let manifestURL = package.appendingPathComponent("Package.swift")
        if (try? String(contentsOf: manifestURL, encoding: .utf8)) != manifest {
            try manifest.write(to: manifestURL, atomically: true, encoding: .utf8)
        }
        let args = ["swift", "build", "--package-path", package.path, "--configuration", configuration, "--product", "Host"]
        let result = try await FoundationProcessRunner(timeout: 120).run(executable: URL(fileURLWithPath: "/usr/bin/xcrun"), arguments: args)
        guard result.status == 0 else { throw E2EFailure("Runtime host build failed: " + String(decoding: result.stderr + result.stdout, as: UTF8.self)) }
        let location: ProcessResult
        do {
            // SwiftPM setup under the full suite is not a five-second tmux operation.
            location = try await FoundationProcessRunner(timeout: 30).run(executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
                arguments: ["swift", "build", "--package-path", package.path, "--configuration", configuration, "--show-bin-path"])
        } catch { throw E2EFailure("P13 \(configuration) host path lookup (xcrun swift build --show-bin-path) failed: \(error)") }
        guard location.status == 0 else { throw E2EFailure("P13 \(configuration) host path lookup (xcrun swift build --show-bin-path) failed: " + String(decoding: location.stderr, as: UTF8.self)) }
        let executable = URL(fileURLWithPath: String(decoding: location.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)).appendingPathComponent("Host")
        if configuration == "release" {
            let signed: ProcessResult
            do {
                signed = try await FoundationProcessRunner(timeout: 30).run(executable: URL(fileURLWithPath: "/usr/bin/codesign"),
                    arguments: ["--force", "--sign", "-", "--options", "runtime", executable.path])
            } catch { throw E2EFailure("P13 release host ad-hoc signing (codesign --sign - --options runtime) failed: \(error)") }
            guard signed.status == 0 else { throw E2EFailure("P13 release host ad-hoc signing (codesign --sign - --options runtime) failed: " + String(decoding: signed.stderr, as: UTF8.self)) }
        }
        return executable
    }
}

@MainActor final class E2EProcessHost {
    let process = Process()
    let directory: URL
    private let input = Pipe()
    private let outputURL: URL
    private var output: FileHandle?
    init(directory: URL) {
        self.directory = directory
        outputURL = directory.appendingPathComponent("host-\(UUID().uuidString).log")
    }
    static func prepare(configuration: String) async throws {
        _ = try await RuntimeHostBuilder.shared.executable(configuration: configuration)
    }
    func start(configuration: String = "debug") async throws {
        process.executableURL = try await RuntimeHostBuilder.shared.executable(configuration: configuration)
        process.arguments = [directory.path]
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: outputURL); output = handle
        process.standardOutput = handle; process.standardError = handle; process.standardInput = input
        try process.run()
        let deadline = ContinuousClock.now + .seconds(6)
        while true {
            let text = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
            if text.contains("\"ready\":true") { return }
            guard process.isRunning, ContinuousClock.now < deadline else { throw E2EFailure("Host failed to become ready: " + text) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    func quit() async throws {
        try input.fileHandleForWriting.close()
        let deadline = ContinuousClock.now + .seconds(3)
        while process.isRunning && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(!process.isRunning, "Clean runtime host quit stalled")
        #expect(process.terminationStatus == 0)
    }
    func kill() { if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) } }
    func dispose() { kill(); try? input.fileHandleForWriting.close(); try? output?.close() }
}
