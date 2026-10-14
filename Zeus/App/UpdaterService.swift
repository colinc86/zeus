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
}

/// Adapter seam for Sparkle's controller, settings observation and quiet pending-update reminders.
@MainActor protocol UpdateDriving: AnyObject {
    var canCheckForUpdates: Bool { get }
    var automaticallyChecksForUpdates: Bool { get set }
    var onChange: (() -> Void)? { get set }
    var onPendingUpdate: ((Bool) -> Void)? { get set }
    func start() throws
    func checkForUpdates()
}

/// Standard Sparkle updates for public releases. Debug and test builds create no controller.
@MainActor @Observable final class UpdaterService: AppUpdating {
    private(set) var canCheckForUpdates = false
    private(set) var hasPendingUpdate = false
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
        canCheckForUpdates = driver.canCheckForUpdates
        automaticChecks = driver.automaticallyChecksForUpdates
    }
}
