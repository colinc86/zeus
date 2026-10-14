import AppKit
import Foundation
import ZeusDesign

/// An explicit Open in Terminal action; tests inject an opener and never launch native UI.
@MainActor
protocol ManagedTerminalOpening {
    func open(commandFile: URL) async throws
}

/// Terminal executes a private .command file. This works without Apple-events entitlements/TCC.
@MainActor
struct NativeManagedTerminalOpener: ManagedTerminalOpening {
    func open(commandFile: URL) async throws {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            throw ManagedSessionError.command(ZeusRuntimeCopy.Managed.terminalAppMissing)
        }
        let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            NSWorkspace.shared.open([commandFile], withApplicationAt: terminal, configuration: configuration) { _, error in
                if let error { continuation.resume(throwing: ManagedSessionError.command(ZeusRuntimeCopy.Managed.terminalFailed)) }
                else { continuation.resume() }
            }
        }
    }
}
