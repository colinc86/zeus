import Foundation
import Sparkle

/// Manual/scheduled checks keep Sparkle's standard UI. Only an explicitly authorized exact update skips clicks.
@MainActor final class SparkleControlUserDriver: NSObject, SPUUserDriver {
    private let standard: any SPUUserDriver
    private var target: (version: String, build: String)?
    private var validatedTarget = false
    private var cancelled = false
    private var downloadCancellation: (() -> Void)?
    private var reply: ((Result<Void, any Error>) -> Void)?
    private let permissionResponse: () -> SUUpdatePermissionResponse
    init(standard: any SPUUserDriver, permissionResponse: @escaping () -> SUUpdatePermissionResponse = {
        SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false)
    }) { self.standard = standard; self.permissionResponse = permissionResponse }
    func beginInstall(version: String, build: String, reply: @escaping (Result<Void, any Error>) -> Void) {
        target = (version, build); self.reply = reply; validatedTarget = false; cancelled = false
    }
    func finishInstall(_ result: Result<Void, any Error>) { let completion = reply; reply = nil; completion?(result) }
    func endCycle() {
        if reply != nil { finishInstall(.failure(AppControlError.updaterUnavailable("The update installation ended before relaunch."))) }
        target = nil; validatedTarget = false; downloadCancellation = nil
    }
    func cancelInstall() { cancelled = true; finishInstall(.failure(CancellationError())); downloadCancellation?() }
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        if target != nil { reply(permissionResponse()) }
        else { standard.show(request, reply: reply) }
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        if target == nil { standard.showUserInitiatedUpdateCheck(cancellation: cancellation) }
    }
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard target != nil else { standard.showUpdateFound(with: appcastItem, state: state, reply: reply); return }
        reply(installationChoice(version: appcastItem.displayVersionString, build: appcastItem.versionString, informationOnly: appcastItem.isInformationOnlyUpdate))
    }
    func installationChoice(version: String, build: String, informationOnly: Bool) -> SPUUserUpdateChoice {
        guard let target, !cancelled, !informationOnly, version == target.version, build == target.build else {
            validatedTarget = false; cancelled = true
            finishInstall(.failure(AppControlError.noKnownUpdate)); return .dismiss
        }
        validatedTarget = true
        return .install
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) { if target == nil { standard.showUpdateReleaseNotes(with: downloadData) } }
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) { if target == nil { standard.showUpdateReleaseNotesFailedToDownloadWithError(error) } }
    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        if target != nil { finishInstall(.failure(AppControlError.noKnownUpdate)); acknowledgement() }
        else { standard.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement) }
    }
    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        if target != nil { finishInstall(.failure(AppControlError.updaterUnavailable(error.localizedDescription))); acknowledgement() }
        else { standard.showUpdaterError(error, acknowledgement: acknowledgement) }
    }
    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        if target == nil { standard.showDownloadInitiated(cancellation: cancellation) }
        else { downloadCancellation = cancellation; if cancelled { cancellation() } }
    }
    func showDownloadDidReceiveExpectedContentLength(_ length: UInt64) { if target == nil { standard.showDownloadDidReceiveExpectedContentLength(length) } }
    func showDownloadDidReceiveData(ofLength length: UInt64) { if target == nil { standard.showDownloadDidReceiveData(ofLength: length) } }
    func showDownloadDidStartExtractingUpdate() { downloadCancellation = nil; if target == nil { standard.showDownloadDidStartExtractingUpdate() } }
    func showExtractionReceivedProgress(_ progress: Double) { if target == nil { standard.showExtractionReceivedProgress(progress) } }
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        if target != nil {
            if validatedTarget && !cancelled { reply(.install) }
            else { finishInstall(.failure(AppControlError.noKnownUpdate)); reply(.dismiss) }
        } else { standard.showReady(toInstallAndRelaunch: reply) }
    }
    func showInstallingUpdate(withApplicationTerminated terminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        if target != nil { finishInstall(.success(())) }
        else { standard.showInstallingUpdate(withApplicationTerminated: terminated, retryTerminatingApplication: retryTerminatingApplication) }
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        if target != nil { finishInstall(.success(())); acknowledgement() }
        else { standard.showUpdateInstalledAndRelaunched(relaunched, acknowledgement: acknowledgement) }
    }
    func dismissUpdateInstallation() { if target == nil { standard.dismissUpdateInstallation() }; endCycle() }
    func showUpdateInFocus() { if target == nil { standard.showUpdateInFocus?() } }
}
