import Foundation
import CryptoKit
import Observation

/// Level 2's guard ordering is testable without AX permission. Storage is injected only after redaction.
@MainActor @Observable
final class FocusObserver {
    @ObservationIgnored let source: any FocusCaptureSource
    @ObservationIgnored private let policies: ObservationSettings
    @ObservationIgnored private let privateApps: () -> [ExcludedApp]
    @ObservationIgnored private let paused: () -> Bool
    /// Redacts in memory and returns a commit closure. Guards are checked AGAIN before that closure may store anything.
    @ObservationIgnored private let prepare: (FocusApplication, FocusRecord) async throws -> (@MainActor () throws -> Void)
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var last: Data?
    @ObservationIgnored private var lastApplication: FocusApplication?
    private(set) var error: String?
    private(set) var isRunning = false
    private var sampling = false

    init(source: any FocusCaptureSource, policies: ObservationSettings, privateApps: @escaping () -> [ExcludedApp],
         paused: @escaping () -> Bool = { false },
         prepare: @escaping (FocusApplication, FocusRecord) async throws -> (@MainActor () throws -> Void)) {
        self.source = source; self.policies = policies; self.privateApps = privateApps; self.paused = paused; self.prepare = prepare
    }
    var hasPermission: Bool { source.isTrusted }
    func start() {
        guard task == nil else { return }
        isRunning = true
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.sample()
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }
    func stop() { task?.cancel(); task = nil; isRunning = false; invalidate() }
    /// Also called before deletes or scope changes so an in-flight model result cannot restore deleted/excluded data.
    func invalidate() { generation &+= 1; last = nil; lastApplication = nil }
    private func allowed(_ app: FocusApplication) -> Bool {
        let policy = policies.policy(2)
        return policy.enabled && policy.consented && source.isTrusted && !source.isSecure && !source.isLocked && !paused()
            && app.bundleID != "com.colinc86.Zeus" && !app.bundleID.hasPrefix("local.zeus.")
            && policy.allows(bundleID: app.bundleID, name: app.name, privateApps: privateApps())
    }
    func sample() async {
        guard !sampling else { return }
        guard let app = source.application, allowed(app) else { last = nil; lastApplication = nil; return }
        sampling = true; defer { sampling = false }
        let token = generation, policy = policies.policy(2)
        do {
            guard let record = try await source.capture(app), token == generation, allowed(app), source.application == app else { return }
            let fingerprint = Data(SHA256.hash(data: Data(record.text.utf8)))
            guard fingerprint != last || app != lastApplication else { return }
            let commit = try await prepare(app, record)
            guard token == generation, allowed(app), source.application == app, policies.policy(2) == policy else { return }
            try commit()
            last = fingerprint; lastApplication = app; error = nil
        } catch {
            // Raw content and underlying Apple-event errors never enter the visible error or a log.
            self.error = "Couldn't save this focus record. Zeus will try again."
        }
    }
}
