import Foundation
import Testing
@testable import Zeus

@MainActor private final class FakeFocusSource: FocusCaptureSource {
    var isTrusted = true
    var isSecure = false
    var isLocked = false
    var application: FocusApplication? = .init(pid: 42, bundleID: "test.editor", name: "Editor")
    var record: FocusRecord? = .init(title: "Review for synthetic@example.invalid", document: "file:///project/Example.swift")
    var calls = 0
    func capture(_ application: FocusApplication) async throws -> FocusRecord? { calls += 1; return record }
}

@MainActor struct LM2FocusTests {
    @Test func hardStopsRunBeforeAXAndUnknownAppsFailClosed() async throws {
        let suite = "zeus-focus-test-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ObservationSettings(defaults: defaults), source = FakeFocusSource()
        var privateApps: [ExcludedApp] = [], commits = 0
        let observer = FocusObserver(source: source, policies: settings, privateApps: { privateApps }) { _, _ in { commits += 1 } }
        await observer.sample(); #expect(source.calls == 0)
        settings.edit(2) { $0.enabled = true; $0.consented = true }
        source.isTrusted = false; await observer.sample(); #expect(source.calls == 0)
        source.isTrusted = true; source.isSecure = true; await observer.sample(); #expect(source.calls == 0)
        source.isSecure = false; source.isLocked = true; await observer.sample(); #expect(source.calls == 0)
        source.isLocked = false; privateApps = [.init(name: "Editor", bundleIDs: ["test.editor"])]
        await observer.sample(); #expect(source.calls == 0)
        privateApps = []; source.application = nil; await observer.sample(); #expect(source.calls == 0)
        source.application = .init(pid: 42, bundleID: "com.colinc86.Zeus", name: "Zeus")
        await observer.sample(); #expect(source.calls == 0); #expect(commits == 0)
    }

    @Test func dedupAndPrivateBrowserNeverReachRedactor() async throws {
        let suite = "zeus-focus-test-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ObservationSettings(defaults: defaults), source = FakeFocusSource()
        settings.edit(2) { $0.enabled = true; $0.consented = true }
        var commits = 0, redactions = 0
        let observer = FocusObserver(source: source, policies: settings, privateApps: { [] }) { _, _ in
            redactions += 1; return { commits += 1 }
        }
        await observer.sample(); await observer.sample()
        #expect(commits == 1); #expect(redactions == 1)
        source.record = nil; await observer.sample()
        #expect(commits == 1); #expect(redactions == 1)
        source.record = .init(title: "Another window")
        await observer.sample(); #expect(commits == 2)
    }

    @Test func disablingLockingDeletingOrSwitchingWhileModelRunsCannotCommit() async throws {
        for change in 0..<4 {
            let suite = "zeus-focus-test-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = ObservationSettings(defaults: defaults), source = FakeFocusSource()
            settings.edit(2) { $0.enabled = true; $0.consented = true }
            var commits = 0
            var waiter: CheckedContinuation<Void, Never>?
            var preparing = false
            let observer = FocusObserver(source: source, policies: settings, privateApps: { [] }) { _, _ in
                preparing = true
                await withCheckedContinuation { waiter = $0 }
                return { commits += 1 }
            }
            let sample = Task { await observer.sample() }
            while !preparing { await Task.yield() }
            switch change {
            case 0: settings.edit(2) { $0.enabled = false }
            case 1: source.isLocked = true
            case 2: observer.invalidate()
            default: source.application = .init(pid: 43, bundleID: "test.other", name: "Other")
            }
            waiter?.resume(); await sample.value
            #expect(commits == 0)
        }
    }

    @Test func writeFailureRetriesAndDoesNotExposeUnderlyingContent() async throws {
        let suite = "zeus-focus-test-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ObservationSettings(defaults: defaults), source = FakeFocusSource()
        settings.edit(2) { $0.enabled = true; $0.consented = true }
        struct Failure: Error {}
        var attempts = 0
        let observer = FocusObserver(source: source, policies: settings, privateApps: { [] }) { _, _ in
            return { attempts += 1; if attempts == 1 { throw Failure() } }
        }
        await observer.sample(); #expect(observer.error != nil)
        await observer.sample(); #expect(attempts == 2); #expect(observer.error == nil)
    }
}
