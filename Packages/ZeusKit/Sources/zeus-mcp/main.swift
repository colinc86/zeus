import Darwin
import Foundation
import ZeusMCPCore

@main
struct ZeusMCPMain {
    static func main() async {
        let firedAt = AgentProcessIdentity.startTime(pid: Int(getpid())).map { Double($0) / 1_000_000 } ?? Date().timeIntervalSince1970
        // Broken stdout must throw EPIPE, not terminate the process before cleanup.
        signal(SIGPIPE, SIG_IGN)
        let options: MCPCommandLineOptions
        do { options = try MCPCommandLineOptions.parse(Array(CommandLine.arguments.dropFirst())) }
        catch {
            MCPStdio.diagnostic("zeus-mcp: \(error.localizedDescription)")
            MCPStdio.diagnostic(MCPCommandLineOptions.usage)
            exit(2)
        }
        if options.showHelp { MCPStdio.diagnostic(MCPCommandLineOptions.usage); return }
        if options.turnEnded { await NativeTurnHook.run(options: options, firedAt: firedAt); return }
        if options.hookSettings {
            do {
                let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
                let directory = URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/Zeus/Hooks")
                let value = try OpenCodeHookSettings.make(bridgePath: CommandLine.arguments[0], socketPath: options.socketPath, directory: directory)
                try FileHandle.standardOutput.write(contentsOf: JSONEncoder().encode(value))
            } catch { MCPStdio.diagnostic("Zeus hook settings: \(error.localizedDescription)"); exit(1) }
            return
        }
        do { try await MCPStdio.run(configuration: .init(agent: options.agent, socketPath: options.socketPath)) }
        catch {
            MCPStdio.diagnostic("zeus-mcp: \(error.localizedDescription)")
            exit(1)
        }
    }
}
