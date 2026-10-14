import Foundation
import Sparkle
import Testing
@testable import Zeus

@MainActor private final class AC2UpdateDriver: UpdateDriving {
    var canCheckForUpdates = true
    var automaticallyChecksForUpdates = false
    var onChange: (() -> Void)?
    var onPendingUpdate: ((Bool) -> Void)?
    var onUpdateFound: ((UpdateCheckResult) -> Void)?
    var result = UpdateCheckResult(available: true, version: "1.1", notes: "A fixture update.")
    var starts = 0, interactiveChecks = 0, silentChecks = 0
    var installs: [String] = []
    var fail = false
    func start() throws { starts += 1 }
    func checkForUpdates() { interactiveChecks += 1 }
    func checkForUpdateInformation() async throws -> UpdateCheckResult {
        silentChecks += 1
        if fail { throw AppControlError.updaterUnavailable("Fixture network error.") }
        onUpdateFound?(result)
        return result
    }
    func installUpdate(version: String) async throws { installs.append(version) }
}

/// All Sparkle callbacks are fake; no updater/controller, network or application relaunch is started.
@MainActor private final class AC2StandardDriver: NSObject, SPUUserDriver {
    var calls: [String] = []
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {}
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { calls.append("check") }
    func showUpdateFound(with item: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) { calls.append("found") }
    func showUpdateReleaseNotes(with data: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}
    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) { calls.append("notFound"); acknowledgement() }
    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) { calls.append("error"); acknowledgement() }
    func showDownloadInitiated(cancellation: @escaping () -> Void) { calls.append("download") }
    func showDownloadDidReceiveExpectedContentLength(_ length: UInt64) {}
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showDownloadDidStartExtractingUpdate() {}
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) { calls.append("ready"); reply(.dismiss) }
    func showInstallingUpdate(withApplicationTerminated terminated: Bool, retryTerminatingApplication: @escaping () -> Void) { calls.append("installing") }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func dismissUpdateInstallation() { calls.append("dismiss") }
}

@MainActor struct AppControlUpdateTests {
    @Test func silentCheckNeverActivatesAndInstallRequiresThatCheckedVersion() async throws {
        let driver = AC2UpdateDriver(); var activations = 0
        let service = UpdaterService(disabledReason: nil, makeDriver: { driver }, activate: { activations += 1 })
        await #expect(throws: AppControlError.noKnownUpdate) { try await service.installUpdate(version: "1.1") }
        let result = try await service.checkForUpdateInformation()
        #expect(result.available && result.version == "1.1" && result.notes == "A fixture update.")
        #expect(service.availableVersion == "1.1" && driver.silentChecks == 1 && driver.interactiveChecks == 0 && activations == 0)
        #expect(!driver.automaticallyChecksForUpdates, "A silent check doesn't grant automatic-check authority")
        await #expect(throws: AppControlError.noKnownUpdate) { try await service.installUpdate(version: "1.2") }
        try await service.installUpdate(version: "1.1")
        #expect(driver.installs == ["1.1"] && activations == 0)
        await #expect(throws: AppControlError.noKnownUpdate) { try await service.installUpdate(version: "1.1") }
        driver.result = .init(available: false, version: nil, notes: nil)
        _ = try await service.checkForUpdateInformation()
        #expect(service.availableVersion == nil)
        await #expect(throws: AppControlError.noKnownUpdate) { try await service.installUpdate(version: "1.1") }
    }
    @Test func failedCheckInvalidatesThePriorInstallAndDebugCreatesNoDriver() async throws {
        let driver = AC2UpdateDriver()
        let service = UpdaterService(disabledReason: nil, makeDriver: { driver }, activate: {})
        _ = try await service.checkForUpdateInformation()
        driver.fail = true
        await #expect(throws: AppControlError.self) { try await service.checkForUpdateInformation() }
        await #expect(throws: AppControlError.noKnownUpdate) { try await service.installUpdate(version: "1.1") }
        var created = 0
        let debug = UpdaterService(disabledReason: "Updates are disabled in Debug builds.", makeDriver: { created += 1; return driver }, activate: {})
        await #expect(throws: AppControlError.updaterUnavailable("Updates are disabled in Debug builds.")) { try await debug.checkForUpdateInformation() }
        await #expect(throws: AppControlError.updaterUnavailable("Updates are disabled in Debug builds.")) { try await debug.installUpdate(version: "1.1") }
        #expect(created == 0)
    }
    @Test func exactNativeBuildInstallsWithoutManualUIAndCallbacksCompleteOnce() {
        let standard = AC2StandardDriver(), driver = SparkleControlUserDriver(standard: AC2StandardDriver())
        let routed = SparkleControlUserDriver(standard: standard)
        var completions = 0, succeeded = false
        routed.beginInstall(version: "1.1", build: "11") { result in completions += 1; if case .success = result { succeeded = true } }
        routed.showUserInitiatedUpdateCheck(cancellation: {})
        #expect(routed.installationChoice(version: "1.1", build: "11", informationOnly: false) == .install)
        var choice: SPUUserUpdateChoice?
        routed.showReady(toInstallAndRelaunch: { choice = $0 })
        #expect(choice == .install && standard.calls.isEmpty)
        routed.showInstallingUpdate(withApplicationTerminated: false, retryTerminatingApplication: {})
        routed.dismissUpdateInstallation()
        #expect(completions == 1 && succeeded)
        routed.showUserInitiatedUpdateCheck(cancellation: {})
        #expect(standard.calls == ["check"], "Ordinary UI resumes after the assistant cycle")
        // No target at all must never auto-install an unsolicited update.
        #expect(driver.installationChoice(version: "1.1", build: "11", informationOnly: false) == .dismiss)
    }
    @Test func changedBuildInformationOnlyOrCancellationCannotRelaunch() {
        for (build, informational) in [("12", false), ("11", true)] {
            let driver = SparkleControlUserDriver(standard: AC2StandardDriver())
            var error: AppControlError?
            driver.beginInstall(version: "1.1", build: "11") { if case .failure(let e) = $0 { error = e as? AppControlError } }
            #expect(driver.installationChoice(version: "1.1", build: build, informationOnly: informational) == .dismiss)
            #expect(error == .noKnownUpdate)
        }
        let driver = SparkleControlUserDriver(standard: AC2StandardDriver())
        driver.beginInstall(version: "1.1", build: "11") { _ in }
        #expect(driver.installationChoice(version: "1.1", build: "11", informationOnly: false) == .install)
        var cancelled = 0, choice: SPUUserUpdateChoice?
        driver.showDownloadInitiated(cancellation: { cancelled += 1 })
        driver.cancelInstall()
        driver.showReady(toInstallAndRelaunch: { choice = $0 })
        #expect(cancelled == 1 && choice == .dismiss)
    }
}
