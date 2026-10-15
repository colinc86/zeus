import Foundation
import Observation
import CoreGraphics
import ImageIO

/// Event-driven Level 3 coordinator. Every suspension is followed by policy/context/generation revalidation.
@MainActor @Observable final class ScreenObserver: ScreenObserving {
    private(set) var permission: ScreenPermission = .notDetermined
    private(set) var lastPermissionRequestGranted: Bool?
    var permissionGrantedRequiresReopen: Bool { lastPermissionRequestGranted == true && permission != .granted }
    private(set) var pause: ScreenPause?
    private(set) var lastError: String?
    @ObservationIgnored private let journal: any FrameJournalStoring
    @ObservationIgnored private let source: any ScreenCapturing
    @ObservationIgnored private let processor: any ScreenFrameRedacting
    @ObservationIgnored private let describer: any ScreenDescribing
    @ObservationIgnored private let coveredReader: any CoveredFrameReading
    @ObservationIgnored private let policy: () -> ScreenPolicy
    @ObservationIgnored private let context: () -> ScreenContext?
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let secondsSinceInput: () -> TimeInterval
    @ObservationIgnored private var wasIdle = false
    @ObservationIgnored private let safety: ScreenSafetyMonitor?
    @ObservationIgnored private var running = false
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var warmup: Task<Void, Never>?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var identity: ScreenContext?
    @ObservationIgnored private var due: Date?
    @ObservationIgnored private var kept: [Date] = []
    @ObservationIgnored private var previous: (ScreenContext, ScreenFingerprint)?
    @ObservationIgnored private var lastResult: ScreenCaptureResult?
    @ObservationIgnored private var completedResult: ScreenCaptureResult?
    @ObservationIgnored private var permissionWasGranted = false
    @ObservationIgnored private var pendingDescriptions = true
    @ObservationIgnored private var lastRetention: (Date, Int)?
    init(journal: any FrameJournalStoring, redactor: any Redactor, policy: @escaping () -> ScreenPolicy,
         context: @escaping () -> ScreenContext?, source: (any ScreenCapturing)? = nil,
         processor: (any ScreenFrameRedacting)? = nil, describer: (any ScreenDescribing)? = nil,
         coveredTextReader: (any CoveredFrameReading)? = nil,
         safety: ScreenSafetyMonitor? = nil, clock: @escaping () -> Date = Date.init,
         secondsSinceInput: (() -> TimeInterval)? = nil) {
        self.journal = journal
        self.policy = {
            var value = policy()
            if source == nil { value.deferDescriptions = value.deferDescriptions || ScreenPowerState.deferDescriptions }
            return value
        }
        self.context = context; self.clock = clock
        self.secondsSinceInput = secondsSinceInput ?? {
            guard source == nil, let any = CGEventType(rawValue: ~0) else { return 0 }
            return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
        }
        self.source = source ?? WindowScreenCapture(); self.processor = processor ?? FrameRedactor(redactor: redactor)
        self.describer = describer ?? FrameDescriber(redactor: redactor)
        self.coveredReader = coveredTextReader ?? CoveredFrameReader()
        self.safety = safety ?? (source == nil ? ScreenSafetyMonitor() : nil)
    }
    isolated deinit { stop() }
    func start() {
        guard !running else { return }; running = true
        wasIdle = policy().enabled && policy().consented && secondsSinceInput() >= 300
        if policy().enabled, policy().consented, let processor = processor as? FrameRedactor {
            warmup = Task(priority: .utility) { await processor.prewarm() }
        }
        safety?.onChange = { [weak self] in self?.contextDidChange(returnedFromIdle: false) }
        safety?.start()
        do {
            var query = JournalQuery(); query.from = clock().addingTimeInterval(-3600)
            query.levels = [.screen]; query.kinds = [.frame, .description]; query.limit = 100_000
            var captures: [String: Date] = [:]
            for item in try journal.items(matching: query) {
                if item.kind == .frame { captures[item.id] = item.time }
                else if let id = item.payload.value.details["frame_id"] { captures[id] = item.time }
            }
            kept = Array(captures.values)
        } catch { lastError = "Zeus couldn't read the recent picture count."; kept = Array(repeating: clock(), count: 120) }
        applyRetention()
        contextDidChange(returnedFromIdle: false); schedule()
    }
    func stop() {
        running = false; warmup?.cancel(); warmup = nil; invalidatePendingCapture(); timer?.cancel(); timer = nil
        safety?.stop(); safety?.onChange = nil; due = nil; identity = nil
    }
    func invalidatePendingCapture() {
        generation = UUID(); work?.cancel(); work = nil
        // A deletion/policy boundary must not leave an in-memory old-frame suppression checkpoint.
        previous = nil; lastResult = nil; completedResult = nil
    }
    private func current() -> ScreenContext? { context().map { safety?.supplement($0) ?? $0 } }
    func contextDidChange(returnedFromIdle: Bool = false) {
        guard running else { return }
        generation = UUID(); work?.cancel(); work = nil
        let next = current()
        if next != identity { due = clock().addingTimeInterval(10) }
        identity = next
        applyRetention()
        updatePermission()
        pause = blocked(next)
        if returnedFromIdle { due = clock(); tick() }
        if pendingDescriptions, !policy().deferDescriptions, pause == nil { describePending() }
        schedule()
    }
    /// Public for deterministic fake-clock tests; the production timer only checks deadlines/permission, not pixels.
    func tick() {
        guard running else { return }
        if policy().enabled, policy().consented {
            let idle = secondsSinceInput() >= 300
            if wasIdle && !idle { due = clock() }
            wasIdle = idle
        }
        applyRetention(); updatePermission(); pause = blocked(current())
        if let due, clock() >= due { captureNow() }
        else if pendingDescriptions, !policy().deferDescriptions, pause == nil { describePending() }
    }
    @discardableResult func requestPermission() -> ScreenPermission {
        guard policy().consented else { return permission }
        lastPermissionRequestGranted = source.requestPermission(); updatePermission(); contextDidChange(returnedFromIdle: false)
        return permission
    }
    func captureOnDemand() async -> ScreenCaptureResult? {
        let token = generation, requested = current()
        if let work { await work.value }
        guard running, generation == token, requested == current(), blocked(current()) == nil else { return nil }
        completedResult = nil; captureNow()
        if let work { await work.value }
        guard running, generation == token, requested == current(), blocked(current()) == nil || blocked(current()) == .cap else { return nil }
        return completedResult
    }
    func captureNow() {
        guard running, work == nil else { return }
        updatePermission()
        let startContext = current()
        pause = blocked(startContext)
        guard pause == nil, let startContext else { return }
        let token = generation, startPolicy = policy(), now = clock()
        due = now.addingTimeInterval(300)
        work = Task { [weak self] in
            guard let self else { return }
            defer { if generation == token { work = nil } }
            do {
                let raw = try await source.capture(startContext)
                guard valid(token, startContext, startPolicy) else { return }
                let fingerprint = try ScreenFingerprint(image: raw.image)
                if let previous, previous.0.bundleID == startContext.bundleID,
                   previous.0.windowTitle == startContext.windowTitle, fingerprint.isUnchanged(from: previous.1) {
                    if let result = lastResult {
                        var query = JournalQuery(); query.limit = 100_000
                        let ids = Set(try journal.items(matching: query).map(\.id))
                        let frame = try result.frameID.flatMap { try journal.frame(id: $0) }
                        let description = result.descriptionID.map { ids.contains($0) } == true ? result.description : nil
                        if frame != nil || description != nil {
                            completedResult = ScreenCaptureResult(identity: result.identity, time: result.time,
                                frameID: frame == nil ? nil : result.frameID, descriptionID: description == nil ? nil : result.descriptionID,
                                frame: frame, description: description)
                        }
                    }
                    return
                }
                let covered = try await processor.redact(raw, context: startContext)
                guard valid(token, startContext, startPolicy) else { return }
                let description = startPolicy.deferDescriptions ? nil : await describer.describe(covered)
                guard valid(token, startContext, startPolicy) else { return }
                let frameID = "frame_" + UUID().uuidString
                let privateImage = description?.value.details["picture_not_kept"] == "private"
                if !privateImage {
                    let metadata = JournalPayload(description: covered.frame.value.appName + " · " + covered.frame.value.windowTitle,
                        details: ["appName": covered.frame.value.appName, "window": covered.frame.value.windowTitle,
                                  "description_pending": startPolicy.deferDescriptions ? "true" : "false"])
                    try journal.appendFrame(covered.frame, item: .init(id: frameID, time: now, level: .screen,
                        app: startContext.bundleID, kind: .frame, payload: .init(metadata, report: covered.frame.report)))
                    pendingDescriptions = true; kept.append(now); previous = (startContext, fingerprint)
                }
                if let description { try storeDescription(description, frameID: frameID, at: now, app: startContext.bundleID) }
                if privateImage { kept.append(now); previous = (startContext, fingerprint) }
                let result = ScreenCaptureResult(identity: .init(bundleID: startContext.bundleID, processID: startContext.processID, windowID: startContext.windowID),
                    time: now, frameID: privateImage ? nil : frameID, descriptionID: description == nil ? nil : "description_" + frameID,
                    frame: privateImage ? nil : covered.frame, description: description)
                lastResult = result; completedResult = result; lastError = nil
            } catch is CancellationError { }
            catch ScreenCaptureError.sensitive { pause = .sensitiveApp }
            catch { lastError = "Zeus couldn't take or keep this picture." }
        }
    }
    private func storeDescription(_ description: Redacted<JournalPayload>, frameID: String, at now: Date, app: String?) throws {
        var payload = description.value; payload.details["frame_id"] = frameID
        try journal.append(.init(id: "description_" + frameID, time: now, level: .screen, app: app, kind: .description,
                                 payload: .init(payload, report: description.report)))
    }
    private func valid(_ token: UUID, _ captured: ScreenContext, _ capturedPolicy: ScreenPolicy) -> Bool {
        updatePermission()
        return running && generation == token && !Task.isCancelled && policy() == capturedPolicy && current() == captured && blocked(current()) == nil
    }
    private func applyRetention() {
        guard policy().enabled, policy().consented else { return }
        let day = Calendar.current.startOfDay(for: clock()), days = policy().descriptionRetentionDays
        guard lastRetention?.0 != day || lastRetention?.1 != days else { return }
        do { try journal.pruneScreens(descriptionDays: days, now: clock()); lastRetention = (day, days) }
        catch { lastError = "Zeus couldn't apply picture retention." }
    }
    private func updatePermission() {
        let granted = source.hasPermission
        if granted { permissionWasGranted = true; permission = .granted; return }
        let wasGranted = permission == .granted
        permission = permissionWasGranted ? .revoked : .denied
        if wasGranted {
            generation = UUID(); work?.cancel(); work = nil
            if policy().enabled && policy().consented {
                do { try journal.append(.init(time: clock(), level: .screen, kind: .description,
                    payload: .init(.init(description: "Screen Recording permission was turned off. No pictures are being taken.")))) }
                catch { lastError = "Zeus couldn't save the Screen Recording permission change." }
            }
        }
    }
    static func sensitiveApp(_ bundle: String) -> Bool {
        let value = bundle.lowercased()
        return ["com.apple.keychainaccess", "com.apple.passwords", "com.agilebits.onepassword7", "com.1password.1password", "com.lastpass.lastpass"].contains(value) ||
            ["bankofamerica", "chase", "wellsfargo", "revolut", "monzo", "banking"].contains { value.contains($0) }
    }
    private func blocked(_ context: ScreenContext?) -> ScreenPause? {
        let policy = policy()
        guard policy.enabled, policy.consented else { return .disabled }
        guard source.hasPermission else { return .permission }
        guard let context else { return .privateContext }
        if context.isLocked { return .locked }
        if context.secureInput { return .secureInput }
        if context.cameraInUse { return .camera }
        if context.isMirrored || context.isPresenting { return .presenting }
        if context.isPrivate || !policy.permits(context) { return .privateContext }
        if Self.sensitiveApp(context.bundleID) { return .sensitiveApp }
        kept.removeAll { clock().timeIntervalSince($0) >= 3600 }
        if kept.count >= max(0, min(policy.capturesPerHour, 120)) { return .cap }
        return nil
    }
    private func schedule() {
        timer?.cancel()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                let delay = min(30, max(1, self?.due?.timeIntervalSince(self?.clock() ?? Date()) ?? 30))
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard let self, running else { return }; tick()
                if let due, due <= clock(), work == nil { self.due = clock().addingTimeInterval(30) }
            }
        }
    }
    /// Deferred text is reconstructed only from already-covered stored pixels, never retained raw OCR.
    private func describePending() {
        guard work == nil else { return }
        let token = generation
        work = Task { [weak self] in
            guard let self else { return }
            defer { if generation == token { work = nil } }
            do {
                var query = JournalQuery(); query.kinds = [.frame, .description]; query.limit = 100_000
                let rows = try journal.items(matching: query)
                let described = Set(rows.filter { $0.kind == .description }.compactMap { $0.payload.value.details["frame_id"] })
                for row in rows where row.kind == .frame && !described.contains(row.id) {
                    guard running, generation == token, !policy().deferDescriptions, blocked(current()) == nil,
                          let frame = try journal.frame(id: row.id) else { return }
                    let covered = try await coveredReader.read(frame)
                    let description = await describer.describe(covered)
                    guard running, generation == token, !Task.isCancelled, policy().enabled, !policy().deferDescriptions,
                          blocked(current()) == nil, try journal.frame(id: row.id) != nil else { return }
                    try storeDescription(description, frameID: row.id, at: row.time, app: row.app)
                    if description.value.details["picture_not_kept"] == "private" { try journal.delete(.item(row.id)) }
                }
                pendingDescriptions = false
            } catch { lastError = "Zeus couldn't describe a kept picture." }
        }
    }
}
