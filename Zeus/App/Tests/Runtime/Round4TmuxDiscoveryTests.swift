import Foundation
import Testing
import ZeusProtocol
@testable import Zeus

@MainActor
struct Round4TmuxDiscoveryTests {
    @Test func missingTmuxDoesNotBurnAttemptsAndInstallingItRepairsExistingConnector() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        let binary = f.directory.appendingPathComponent("bin/tmux")
        let runner = FakeProcessRunner()
        let connector = TmuxConnector(executableResolver: { TmuxExecutable.resolve(paths: [binary.path]) }, runner: runner)
        f.routing.deliveryMethod = .tmux; f.routing.tmuxTarget = "%0"
        let runtime = ZeusRuntime(cards: f.cards, status: f.status, characters: f.characters, routing: f.routing,
            clock: f.clock, socketPath: f.directory.appendingPathComponent("install.sock").path,
            ledgerURL: f.directory.appendingPathComponent("install.json"), connectors: [connector])
        try runtime.start(); defer { runtime.stop() }
        runtime.registerSession(connectorSession(pane: "%0"))
        if case .queued = await runtime.sendUserMessage("Install while open") {} else { Issue.record("Expected missing executable queue") }
        let id = try #require(runtime.ledger?.records.first?.delivery.id)
        #expect(runtime.ledger?.record(id: id)?.delivery.attempts == 0)
        #expect(await runner.rawCalls.isEmpty)
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        f.clock.advance(5); runtime.processDueDeliveries()
        try await eventually { runtime.userMessageDeliveries.first?.state == .delivered && runtime.sends.isEmpty }
        #expect(runtime.ledger?.record(id: id)?.delivery.attempts == 1)
        #expect(await runner.rawCalls.allSatisfy { $0.executable == binary })
    }
    @Test func guiDiscoveryAndManagedLaunchAgreeOnUserLocalAndPATHInstalls() throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        let binary = f.directory.appendingPathComponent(".local/bin/tmux")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let env = ["HOME": f.directory.path, "PATH": "/tmp/custom/bin:relative:."]
        #expect(TmuxExecutable.resolve(environment: env) == binary)
        #expect(ManagedExecutables.detect(environment: env).tmux == binary)
        #expect(TmuxExecutable.searchPaths(environment: env).contains("/tmp/custom/bin/tmux"))
        #expect(!TmuxExecutable.searchPaths(environment: env).contains("relative/tmux"))
        #expect(TmuxPaneDiscovery.resolveExecutable() == TmuxExecutable.resolve())
    }
}
