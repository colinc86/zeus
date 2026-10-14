import Foundation
import Sparkle

/// Keeps Sparkle and its KVO callbacks behind the app's update seam. No request headers or credentials.
@MainActor final class SparkleUpdateDriver: NSObject, UpdateDriving, SPUStandardUserDriverDelegate, SPUUpdaterDelegate {
    var onChange: (() -> Void)?
    var onPendingUpdate: ((Bool) -> Void)?
    var onUpdateFound: ((UpdateCheckResult) -> Void)?
    private lazy var userDriver: SparkleControlUserDriver = SparkleControlUserDriver(standard: SPUStandardUserDriver(hostBundle: .main, delegate: self), permissionResponse: { [weak self] in
        SUUpdatePermissionResponse(automaticUpdateChecks: self?.updater.automaticallyChecksForUpdates ?? false,
                                   sendSystemProfile: self?.updater.sendsSystemProfile ?? false)
    })
    private lazy var updater: SPUUpdater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: userDriver, delegate: self)
    private var informationReply: CheckedContinuation<UpdateCheckResult, any Error>?
    private var informationResult: UpdateCheckResult?
    private var checkedBuild: (version: String, build: String)?
    private var timeoutTask: Task<Void, Never>?
    private var observations: [NSKeyValueObservation] = []
    var canCheckForUpdates: Bool { updater.canCheckForUpdates }
    var automaticallyChecksForUpdates: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue }
    }

    func start() throws {
        // The throwing API lets our Settings show startup failures without a modal configuration alert.
        try updater.start()
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.onChange?() }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.onChange?() }
            }
        ]
    }
    func checkForUpdates() { updater.checkForUpdates() }

    func checkForUpdateInformation() async throws -> UpdateCheckResult {
        guard informationReply == nil, updater.canCheckForUpdates, !updater.sessionInProgress else { throw AppControlError.updaterUnavailable("An update check is already in progress.") }
        checkedBuild = nil; informationResult = nil
        return try await withCheckedThrowingContinuation { reply in
            informationReply = reply
            timeoutTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                self?.finishInformation(.failure(AppControlError.updaterUnavailable("The update check timed out.")))
            }
            updater.checkForUpdateInformation()
        }
    }
    func installUpdate(version: String) async throws {
        guard let checkedBuild, checkedBuild.version == version else { throw AppControlError.noKnownUpdate }
        guard updater.canCheckForUpdates, !updater.sessionInProgress else { throw AppControlError.updaterUnavailable("An update operation is already in progress.") }
        self.checkedBuild = nil
        try Task.checkCancellation()
        let requestID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Void, any Error>) in
                userDriver.beginInstall(version: version, build: checkedBuild.build, requestID: requestID) { reply.resume(with: $0) }
                if Task.isCancelled { userDriver.cancelInstall(requestID: requestID, cycleStarted: false) } else { updater.checkForUpdates() }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.userDriver.cancelInstall(requestID: requestID, cycleStarted: self.updater.sessionInProgress)
            }
        }
    }
    private func finishInformation(_ result: Result<UpdateCheckResult, any Error>) {
        guard let reply = informationReply else { return }
        informationReply = nil; timeoutTask?.cancel(); timeoutTask = nil
        reply.resume(with: result)
    }
    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        MainActor.assumeIsolated {
            let result = UpdateCheckResult(available: !item.isInformationOnlyUpdate, version: item.displayVersionString, notes: item.itemDescription)
            onUpdateFound?(result)
            if informationReply != nil {
                informationResult = result
                checkedBuild = result.available ? (item.displayVersionString, item.versionString) : nil
            }
        }
    }
    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        MainActor.assumeIsolated {
            let result = UpdateCheckResult(available: false, version: nil, notes: nil)
            onUpdateFound?(result)
            if informationReply != nil { informationResult = result; checkedBuild = nil }
        }
    }
    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        MainActor.assumeIsolated {
            if let result = informationResult { finishInformation(.success(result)) }
            else if let error { finishInformation(.failure(AppControlError.updaterUnavailable(error.localizedDescription))) }
            else { finishInformation(.failure(AppControlError.updaterUnavailable("The update check finished without a result."))) }
            informationResult = nil
            if let error { userDriver.finishInstall(.failure(AppControlError.updaterUnavailable(error.localizedDescription))) }
            userDriver.endCycle()
            onChange?()
        }
    }

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        // Zeus is a background app. Even a check near launch must never steal focus.
        false
    }
    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        // Sparkle's standard UI invokes its Objective-C delegate on the main thread.
        MainActor.assumeIsolated {
            if !state.userInitiated && !handleShowingUpdate { onPendingUpdate?(true) }
        }
    }
    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { onPendingUpdate?(false) }
    }
    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { onPendingUpdate?(false) }
    }
}
