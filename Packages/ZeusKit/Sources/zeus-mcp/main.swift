import Darwin
import ZeusMCPCore

@main
struct ZeusMCPMain {
    static func main() async {
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
        do { try await MCPStdio.run(configuration: .init(agent: options.agent, socketPath: options.socketPath)) }
        catch {
            MCPStdio.diagnostic("zeus-mcp: \(error.localizedDescription)")
            exit(1)
        }
    }
}
