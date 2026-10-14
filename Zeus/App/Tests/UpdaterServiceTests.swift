import Foundation
import Sparkle
import SwiftUI
import Testing
@testable import Zeus

@MainActor private final class FakeUpdateDriver: UpdateDriving {
    var canCheckForUpdates = true
    var automaticallyChecksForUpdates = true { didSet { writes += 1; onChange?() } }
    var onChange: (() -> Void)?
    var onPendingUpdate: ((Bool) -> Void)?
    var starts = 0, checks = 0, writes = 0
    var fails = false
    func start() throws { starts += 1; if fails { throw CocoaError(.fileReadUnknown) } }
    func checkForUpdates() { checks += 1; canCheckForUpdates = false; onChange?() }
}

@MainActor struct UpdaterServiceTests {
    @Test func debugAndTestHostsNeverCreateStartOrCheckAController() {
        for (debug, host) in [(true, false), (true, true), (false, true)] {
            var factories = 0, activations = 0
            let driver = FakeUpdateDriver()
            let service = UpdaterService(disabledReason: UpdaterService.disabledReason(debug: debug, testHost: host,
                publicKey: Data(repeating: 1, count: 32).base64EncodedString()),
                makeDriver: { factories += 1; return driver }, activate: { activations += 1 })
            service.start(); service.checkForUpdates(); service.automaticallyChecksForUpdates = true
            #expect(!service.isAvailable && !service.canCheckForUpdates)
            #expect(factories == 0 && activations == 0 && driver.starts == 0 && driver.checks == 0 && driver.writes == 0)
        }
        #if DEBUG
        let real = UpdaterService(); real.start(); real.checkForUpdates()
        #expect(!real.isAvailable && real.unavailableReason == "Updates are disabled in Debug builds.")
        #endif
    }

    @Test func placeholderOrInvalidSigningKeysDisableUpdatesUntilConfigured() {
        for key in [nil, "not-a-key", Data(repeating: 0, count: 31).base64EncodedString()] {
            #expect(UpdaterService.disabledReason(debug: false, testHost: false, publicKey: key) != nil)
        }
        #expect(UpdaterService.disabledReason(debug: false, testHost: false,
            publicKey: Data(repeating: 1, count: 32).base64EncodedString()) == nil)
    }

    @Test func startIsIdempotentAndManualChecksActivateOnlyWhenEnabled() {
        let driver = FakeUpdateDriver(); var factories = 0, activations = 0
        let service = UpdaterService(disabledReason: nil, makeDriver: { factories += 1; return driver }, activate: { activations += 1 })
        #expect(!service.canCheckForUpdates)
        service.checkForUpdates(); #expect(factories == 0 && activations == 0)
        service.start(); service.start()
        #expect(factories == 1 && driver.starts == 1 && service.canCheckForUpdates)
        service.checkForUpdates(); service.checkForUpdates()
        #expect(activations == 1 && driver.checks == 1 && !service.canCheckForUpdates)
        driver.canCheckForUpdates = true; driver.onChange?()
        #expect(service.canCheckForUpdates)
    }

    @Test func settingsBindingWritesSparklesPreferenceAndObservesExternalChanges() {
        let driver = FakeUpdateDriver()
        let service = UpdaterService(disabledReason: nil, makeDriver: { driver }, activate: {})
        service.start(); #expect(service.automaticallyChecksForUpdates)
        let binding = UpdateSettingsView.automaticChecksBinding(service)
        binding.wrappedValue = false
        #expect(!driver.automaticallyChecksForUpdates && !binding.wrappedValue && driver.writes == 1)
        binding.wrappedValue = false; #expect(driver.writes == 1)
        driver.automaticallyChecksForUpdates = true
        #expect(binding.wrappedValue && driver.writes == 2)
    }

    @Test func quietRemindersChangeTheMenuWithoutActivatingAndClearOnAttention() {
        let driver = FakeUpdateDriver(); var activations = 0
        let service = UpdaterService(disabledReason: nil, makeDriver: { driver }, activate: { activations += 1 })
        service.start(); #expect(service.menuTitle == "Check for Updates…")
        driver.onPendingUpdate?(true)
        #expect(service.menuTitle == "Update Available…" && activations == 0 && service.canCheckForUpdates)
        service.checkForUpdates(); #expect(driver.checks == 1 && activations == 1)
        driver.onPendingUpdate?(false); #expect(service.menuTitle == "Check for Updates…")
        let sparkle = SparkleUpdateDriver() // Controller is lazy: delegate-only calls never create/start it.
        var pending: [Bool] = []; sparkle.onPendingUpdate = { pending.append($0) }
        #expect(sparkle.supportsGentleScheduledUpdateReminders)
        for immediate in [true, false] {
            #expect(!sparkle.standardUserDriverShouldHandleShowingScheduledUpdate(.empty(), andInImmediateFocus: immediate))
        }
        sparkle.standardUserDriverDidReceiveUserAttention(forUpdate: .empty())
        sparkle.standardUserDriverWillFinishUpdateSession()
        #expect(pending == [false, false])
    }

    @Test func startupFailureStaysDisabledAndDoesNotActivateOrCheck() {
        let driver = FakeUpdateDriver(); driver.fails = true; var activations = 0
        let service = UpdaterService(disabledReason: nil, makeDriver: { driver }, activate: { activations += 1 })
        service.start(); service.start(); service.checkForUpdates()
        driver.onChange?()
        #expect(!service.isAvailable && !service.canCheckForUpdates && service.unavailableReason?.contains("Couldn't start") == true)
        #expect(driver.starts == 1 && driver.checks == 0 && activations == 0)
    }
}
