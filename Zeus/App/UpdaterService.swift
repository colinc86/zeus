import AppKit
import Foundation
import Observation

/// App-facing update controls. Settings can bind to a fake without starting Sparkle or using the network.
@MainActor protocol AppUpdating: AnyObject {
    var isAvailable: Bool { get }
    var unavailableReason: String? { get }
    var canCheckForUpdates: Bool { get }
    var menuTitle: String { get }
    var automaticallyChecksForUpdates: Bool { get set }
    func checkForUpdates()
    var availableVersion: String? { get }
    func checkForUpdateInformation() async throws -> UpdateCheckResult
    func installUpdate(version: String) async throws
}

extension AppUpdating {
    var availableVersion: String? { nil }
    func checkForUpdateInformation() async throws -> UpdateCheckResult { throw AppControlError.updaterUnavailable(unavailableReason ?? "Updates are unavailable.") }
    func installUpdate(version: String) async throws { throw AppControlError.updaterUnavailable(unavailableReason ?? "Updates are unavailable.") }
}

/// Adapter seam for Sparkle's controller, settings observation and quiet pending-update reminders.
@MainActor protocol UpdateDriving: AnyObject {
    var canCheckForUpdates: Bool { get }
    var automaticallyChecksForUpdates: Bool { get set }
    var onChange: (() -> Void)? { get set }
    var onPendingUpdate: ((Bool) -> Void)? { get set }
    func start() throws
    func checkForUpdates()
    var onUpdateFound: ((UpdateCheckResult) -> Void)? { get set }
    func checkForUpdateInformation() async throws -> UpdateCheckResult
    func installUpdate(version: String) async throws
}

extension UpdateDriving {
    var onUpdateFound: ((UpdateCheckResult) -> Void)? { get { nil } set {} }
    func checkForUpdateInformation() async throws -> UpdateCheckResult { throw AppControlError.updaterUnavailable("Silent update checks are unavailable.") }
    func installUpdate(version: String) async throws { throw AppControlError.updaterUnavailable("Assistant update installation is unavailable.") }
}

/// Standard Sparkle updates for public releases. Debug and test builds create no controller.
@MainActor @Observable final class UpdaterService: AppUpdating {
    private(set) var canCheckForUpdates = false
    private(set) var hasPendingUpdate = false
    private(set) var availableVersion: String?
    @ObservationIgnored private var lastCheckedVersion: String?
    @ObservationIgnored private var controlOperation = false
    private var automaticChecks = false
    private(set) var unavailableReason: String?
    var isAvailable: Bool { unavailableReason == nil }
    var menuTitle: String { hasPendingUpdate ? "Update Available…" : "Check for Updates…" }
    var automaticallyChecksForUpdates: Bool {
        get { automaticChecks }
        set {
            guard isAvailable, let driver, driver.automaticallyChecksForUpdates != newValue else { return }
            driver.automaticallyChecksForUpdates = newValue
            refresh()
        }
    }
    @ObservationIgnored private let makeDriver: () -> any UpdateDriving
    @ObservationIgnored private let activate: () -> Void
    @ObservationIgnored private var driver: (any UpdateDriving)?
    @ObservationIgnored private var started = false

    static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// Invalid/missing signing metadata never triggers a misconfigured Sparkle startup prompt.
    static func disabledReason(debug: Bool, testHost: Bool, publicKey: String?) -> String? {
        if debug { return "Updates are disabled in Debug builds." }
        if testHost { return "Updates are disabled while tests are running." }
        guard let publicKey, Data(base64Encoded: publicKey)?.count == 32 else {
            return "Updates aren't configured in this build."
        }
        return nil
    }

    convenience init() {
        self.init(disabledReason: Self.disabledReason(debug: Self.isDebugBuild,
            testHost: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil,
            publicKey: Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String),
            makeDriver: { SparkleUpdateDriver() }, activate: { NSApplication.shared.activate() })
    }

    /// Inject only a fake driver in tests; no Sparkle controller is created until an eligible start.
    init(disabledReason: String?, makeDriver: @escaping () -> any UpdateDriving, activate: @escaping () -> Void) {
        unavailableReason = disabledReason
        self.makeDriver = makeDriver
        self.activate = activate
    }

    func start() {
        guard isAvailable, !started else { return }
        started = true
        let driver = makeDriver()
        self.driver = driver
        driver.onChange = { [weak self] in self?.refresh() }
        driver.onPendingUpdate = { [weak self] pending in self?.hasPendingUpdate = pending }
        driver.onUpdateFound = { [weak self] result in self?.availableVersion = result.available ? result.version : nil }
        do {
            try driver.start()
            refresh()
        } catch {
            unavailableReason = "Couldn't start updates. Quit and reopen Zeus to try again."
            canCheckForUpdates = false
        }
    }

    func checkForUpdates() {
        guard isAvailable, canCheckForUpdates, let driver else { return }
        // Close the immediate double-click window before Sparkle publishes its busy state.
        canCheckForUpdates = false
        activate()
        driver.checkForUpdates()
        refresh()
    }

    private func refresh() {
        guard isAvailable, let driver else { return }
        canCheckForUpdates = driver.canCheckForUpdates && !controlOperation
        automaticChecks = driver.automaticallyChecksForUpdates
    }

    func checkForUpdateInformation() async throws -> UpdateCheckResult {
        start()
        guard isAvailable, let driver else { throw AppControlError.updaterUnavailable(unavailableReason ?? "Updates are unavailable.") }
        guard !controlOperation, driver.canCheckForUpdates else { throw AppControlError.updaterUnavailable("An update check is already in progress.") }
        controlOperation = true; lastCheckedVersion = nil; refresh()
        defer { controlOperation = false; refresh() }
        let result = try await driver.checkForUpdateInformation()
        lastCheckedVersion = result.available ? result.version : nil
        availableVersion = lastCheckedVersion
        hasPendingUpdate = result.available
        return result
    }

    func installUpdate(version: String) async throws {
        start()
        guard isAvailable, let driver else { throw AppControlError.updaterUnavailable(unavailableReason ?? "Updates are unavailable.") }
        guard version == lastCheckedVersion else { throw AppControlError.noKnownUpdate }
        guard !controlOperation, driver.canCheckForUpdates else { throw AppControlError.updaterUnavailable("An update operation is already in progress.") }
        controlOperation = true; lastCheckedVersion = nil; refresh()
        defer { controlOperation = false; refresh() }
        try await driver.installUpdate(version: version)
    }
}
