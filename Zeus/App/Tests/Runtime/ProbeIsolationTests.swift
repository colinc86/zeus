import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

@MainActor
struct ProbeIsolationTests {
    @Test func disposableHomeRejectsSiblingSymlinkAndConflictingHome() throws {
        let root = URL(fileURLWithPath: "/private/tmp/zfx10_" + UUID().uuidString)
        let home = root.appendingPathComponent("home")
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let env = ["HOME": home.path, "CFFIXED_USER_HOME": home.path]
        try ManagedProbeIsolation.validate(folder: home.appendingPathComponent("project").path, environment: env)
        #expect(throws: (any Error).self) { try ManagedProbeIsolation.validate(folder: outside.path, environment: env) }
        #expect(throws: (any Error).self) { try ManagedProbeIsolation.validate(folder: home.path + "-sibling", environment: env) }
        #expect(throws: (any Error).self) { try ManagedProbeIsolation.home(["HOME": home.path, "CODEX_HOME": outside.path]) }
        let link = home.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(throws: (any Error).self) { try ManagedProbeIsolation.validate(folder: link.path, environment: env) }
        #expect(throws: (any Error).self) { try ManagedProbeIsolation.home([:]) }
        #expect(throws: (any Error).self) { try ManagedProbeIsolation.home(["HOME": home.path, "CFFIXED_USER_HOME": outside.path]) }
        #expect(throws: (any Error).self) { try ManagedProbeIsolation.validateSocket(nil, environment: env, isolatedSocket: nil) }
        #expect(throws: (any Error).self) { try ManagedProbeIsolation.validateSocket("/private/tmp/tmux-501/default", environment: env, isolatedSocket: "/private/tmp/tmux-501/default") }
    }

    @Test func savedOutsideFolderCannotLaunchOrRestart() async throws {
        let fixture = try ManagedFixture()
        defer { fixture.cleanup() }
        fixture.config.value?.folder = fixture.folder.deletingLastPathComponent().appendingPathComponent("outside-" + UUID().uuidString).path
        fixture.controller.activate()
        try await fixture.settle()
        #expect(await fixture.host.creates.isEmpty)
        #expect(await fixture.host.commands.isEmpty)
        if case .failed(let reason) = fixture.controller.managedStatus {
            #expect(reason.contains("disposable HOME"))
        } else { Issue.record("An escaped saved folder must fail closed") }
        fixture.controller.restartManagedSession()
        try await fixture.settle()
        #expect(await fixture.host.stops == 0)
        #expect(await fixture.host.commands.isEmpty)
    }

    @Test func directTmuxLaunchRejectsEscapedFolderBeforeRunningAProcess() async throws {
        let root = "/private/tmp/zfx10_" + UUID().uuidString
        let runner = IsolationRunner()
        let host = ManagedTmux(executable: URL(fileURLWithPath: "/bin/false"), runner: runner,
            environment: ["HOME": root + "/home"], testSocket: root + "/tmux.sock")
        await #expect(throws: (any Error).self) {
            _ = try await host.create(name: "zeus", owner: "fixture", folder: root + "/outside")
        }
        #expect(await runner.calls == 0)
    }

    #if DEBUG
    @Test func invalidComposerEnvironmentStillSelectsTheProbeBranch() throws {
        #expect(!ComposerGrowthProbe.isRequested([:]))
        #expect(ComposerGrowthProbe.isRequested(["ZEUS_COMPOSER_GROWTH_PROBE": "0"]))
        #expect(throws: (any Error).self) { try ComposerGrowthProbe.validatedHome(["ZEUS_COMPOSER_GROWTH_PROBE": "1"]) }
        let home = "/private/tmp/zcomposer_" + UUID().uuidString
        let env = ["ZEUS_COMPOSER_GROWTH_PROBE": "1", "HOME": home, "CFFIXED_USER_HOME": home, "TMUX_TMPDIR": home + "/tmux"]
        #expect(try ComposerGrowthProbe.validatedHome(env).path == home)
        var invalid = env; invalid["CFFIXED_USER_HOME"] = home + "-different"
        #expect(throws: (any Error).self) { try ComposerGrowthProbe.validatedHome(invalid) }
    }
    #endif
}

private actor IsolationRunner: ProcessRunning {
    var calls = 0
    func run(executable: URL, arguments: [String], input: Data?) async throws -> ProcessResult {
        calls += 1
        return .init(status: 1, stdout: Data(), stderr: Data())
    }
}
