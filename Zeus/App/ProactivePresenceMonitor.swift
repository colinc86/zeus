import AppKit

/// Reports only recent input timestamps. It never installs a recorder or reads event contents.
@MainActor final class ProactivePresenceMonitor {
    private var task: Task<Void, Never>?
    private var enabled = false
    private var lastReported: Date?
    var now: () -> Date = Date.init
    var secondsSinceInput: () -> TimeInterval = {
        guard let any = CGEventType(rawValue: ~0) else { return .infinity }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }
    var report: (Date) -> Void = { _ in }
    isolated deinit { task?.cancel() }

    func configure(enabled: Bool) {
        self.enabled = enabled
        guard enabled else { task?.cancel(); task = nil; return }
        check()
        guard task == nil else { return }
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                self?.check()
            }
        }
    }
    func check() {
        guard enabled else { return }
        let age = secondsSinceInput()
        guard age.isFinite, age >= 0, age <= 30 else { return }
        reportIfNew(now().addingTimeInterval(-age))
    }
    func interacted() { if enabled { reportIfNew(now()) } }
    private func reportIfNew(_ date: Date) {
        guard lastReported.map({ date.timeIntervalSince($0) > 0.1 }) ?? true else { return }
        lastReported = date; report(date)
    }
    func stop() { configure(enabled: false) }
}
