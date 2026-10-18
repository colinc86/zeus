import Foundation
@testable import Zeus

/// Owns a short, private socket path; callers defer stop immediately after construction.
struct PrivateTestTmuxRunner: ProcessRunning {
    let directory: URL
    var socket: String { directory.appendingPathComponent("sock").path }

    init() throws {
        directory = URL(fileURLWithPath: "/private/tmp/ztmux_" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
    }

    func run(executable: URL, arguments: [String], input: Data?) async throws -> ProcessResult {
        try await FoundationProcessRunner().run(executable: executable,
            arguments: ["-S", socket, "-f", "/dev/null"] + arguments, input: input)
    }

    func stop(executable: URL) {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-S", socket, "kill-server"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            try FileManager.default.removeItem(at: directory)
        } catch {
            // Keep the private directory if cleanup could not run.
        }
    }
}
