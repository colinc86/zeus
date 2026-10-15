import Carbon
import Foundation
import FoundationModels
import Observation

/// Raw keys exist only in the bounded current run. Deferred work holds stage-one output in RAM, never on disk.
@MainActor @Observable final class TypingObserver: TypingObserving {
    private(set) var permission: TypingPermission = .notDetermined
    private(set) var lastPermissionRequestGranted: Bool?
    private(set) var permissionGrantedRequiresReopen = false
    private(set) var privateInput = false
    private(set) var isRecording = false
    private(set) var pause: TypingPause?
    private(set) var lastError: String?
    @ObservationIgnored private let journal: any TypingJournalStoring
    @ObservationIgnored private let source: any TypingEventSource
    @ObservationIgnored private let processor: any TypingRunRedacting
    @ObservationIgnored private let summarizer: any TypingTopicSummarizing
    @ObservationIgnored private let policy: () -> TypingPolicy
    @ObservationIgnored private let context: () -> TypingContext?
    @ObservationIgnored private let modelAvailable: () -> Bool
    @ObservationIgnored private let secureInput: () -> Bool
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let productionPower: Bool
    @ObservationIgnored private var running = false
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var currentRun: Run?
    @ObservationIgnored private var lastContext: TypingContext?
    @ObservationIgnored private var pending: [Pending] = []
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var workID: UUID?
    @ObservationIgnored private var nextTapAttempt = Date.distantPast
    private struct Run {
        let id = UUID().uuidString
        let context: TypingContext
        let started: Date
        var lastKey: Date
        var chunks: [String] = []
        var characterCount = 0
        var imeCount = 0
        var pasteCount = 0
        var text: String { chunks.joined() }
    }
    private struct Pending {
        let run: Run
        let firstPass: Redacted<String>
        let policy: TypingPolicy
        let generation: UUID
    }
    init(journal: any TypingJournalStoring, redactor: any Redactor,
         policy: @escaping () -> TypingPolicy, context: @escaping () -> TypingContext?,
         source: (any TypingEventSource)? = nil, processor: (any TypingRunRedacting)? = nil,
         summarizer: (any TypingTopicSummarizing)? = nil,
         modelAvailable: @escaping () -> Bool = { SystemLanguageModel.default.isAvailable },
         secureInput: @escaping () -> Bool = { IsSecureEventInputEnabled() }, clock: @escaping () -> Date = Date.init) {
        self.journal = journal; self.policy = policy; self.context = context; self.clock = clock
        self.source = source ?? MacTypingEventSource(); self.processor = processor ?? RunRedactor(redactor: redactor)
        self.summarizer = summarizer ?? TopicSummarizer(); self.modelAvailable = modelAvailable; self.secureInput = secureInput
        productionPower = source == nil
    }
    private var settings: TypingPolicy {
        var value = policy()
        if productionPower { value.deferProcessing = value.deferProcessing || ScreenPowerState.deferDescriptions }
        return value
    }
    func start() {
        guard !running else { return }; running = true; tick()
        timer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                self?.tick()
            }
        }
    }
    func stop() {
        running = false; timer?.cancel(); timer = nil; source.stop(); isRecording = false
        privateInput = false; pause = .disabled
        invalidatePendingCapture()
    }
    isolated deinit { stop() }
    @discardableResult func requestPermission() -> TypingPermission {
        guard policy().consented else { return permission }
        lastPermissionRequestGranted = source.requestPermission(); nextTapAttempt = .distantPast
        updatePermission()
        permissionGrantedRequiresReopen = lastPermissionRequestGranted == true && !source.hasPermission
        if running { tick() }; return permission
    }
    func invalidatePendingCapture() {
        generation = UUID(); currentRun = nil; pending.removeAll(); idleTask?.cancel(); idleTask = nil
        lastContext = nil
        work?.cancel(); work = nil; workID = nil; source.resetTranslation()
    }
    func contextDidChange() {
        guard running else { return }
        if readableContext() != nil { finishRun() } else { invalidatePendingCapture() }
        source.resetTranslation(); nextTapAttempt = .distantPast; tick()
    }
    private func updatePermission() {
        let prior = permission
        if source.hasPermission { permission = .granted; permissionGrantedRequiresReopen = false }
        else { permission = prior == .granted || prior == .revoked ? .revoked : (lastPermissionRequestGranted == nil ? .notDetermined : .denied) }
        if prior == .granted, permission == .revoked {
            permissionGrantedRequiresReopen = false
            source.stop(); isRecording = false; invalidatePendingCapture()
            if policy().enabled && policy().consented {
                do { try journal.append(.init(time: clock(), level: .typed, kind: .outcome, payload: .init(.init(description: "Input Monitoring is off. Typing is not recorded.")))) }
                catch { lastError = "Zeus couldn't save the Input Monitoring change." }
            }
        }
    }
    /// Called by the one-second secure-input watchdog and by deterministic fixtures. No permission prompt.
    func tick() {
        guard running else { return }
        updatePermission()
        let value = settings
        guard value.enabled, value.consented, modelAvailable(), permission == .granted else {
            pause = !value.enabled || !value.consented ? .disabled : (!modelAvailable() ? .modelUnavailable : .permission)
            privateInput = false; source.stop(); isRecording = false; invalidatePendingCapture(); return
        }
        let readable = readableContext()
        if !isRecording, readable != nil, clock() >= nextTapAttempt, !value.apps.isEmpty {
            nextTapAttempt = clock().addingTimeInterval(60)
            isRecording = source.start(shouldRead: { [weak self] in self?.readableContext() != nil },
                onKey: { [weak self] in self?.receive($0) }, onDisabled: { [weak self] in self?.tapDisabled() })
            if !isRecording { pause = .permission }
        }
        if let run = currentRun, clock().timeIntervalSince(run.lastKey) >= 2 { finishRun() }
        pending.removeAll { clock().timeIntervalSince($0.run.lastKey) >= 600 }
        startWork()
    }
    private func tapDisabled() {
        source.stop(); isRecording = false; invalidatePendingCapture(); nextTapAttempt = .distantPast
        // Revocation is also polled on the watchdog, since there is no guaranteed system callback.
        updatePermission()
    }
    private func readableContext() -> TypingContext? {
        let value = settings
        guard value.enabled, value.consented, modelAvailable(), source.hasPermission else {
            privateInput = false
            pause = !value.enabled || !value.consented ? .disabled : (!modelAvailable() ? .modelUnavailable : .permission)
            invalidatePendingCapture(); return nil
        }
        if secureInput() { privateInput = true; pause = .secureInput; invalidatePendingCapture(); return nil }
        let candidate = context()
        privateInput = candidate?.secureInput == true
        let reason: TypingPause?
        if !value.enabled || !value.consented { reason = .disabled }
        else if !modelAvailable() { reason = .modelUnavailable }
        else if !source.hasPermission { reason = .permission }
        else if privateInput { reason = .secureInput }
        else if candidate?.isLocked == true { reason = .locked }
        else if candidate.map({ $0.isPrivate || !value.permits($0) }) ?? true { reason = .privateContext }
        else { reason = nil }
        pause = reason
        if reason != nil { invalidatePendingCapture(); return nil }
        if let candidate, let previous = lastContext, previous != candidate { finishRun(); source.resetTranslation() }
        lastContext = candidate
        return candidate
    }
    /// Event source has already excluded synthetic keys and rechecked all gates before translation.
    func receive(_ key: TypingKey) {
        guard running, let context = readableContext() else { return }
        let now = clock()
        if let run = currentRun, run.context != context || now.timeIntervalSince(run.lastKey) >= 2 { finishRun() }
        switch key {
        case .invalidate: currentRun = nil; source.resetTranslation(); return
        case .backspace:
            if let chunk = currentRun?.chunks.last {
                currentRun?.chunks.removeLast(); currentRun?.characterCount -= chunk.count; currentRun?.lastKey = now
            }
        case .text(let text):
            if (currentRun?.imeCount ?? 0) > 0 { finishRun() }
            if text.isEmpty {
                if currentRun == nil { currentRun = Run(context: context, started: now, lastKey: now) }
                currentRun?.lastKey = now
            }
            for character in text {
                if currentRun == nil { currentRun = Run(context: context, started: now, lastKey: now) }
                currentRun?.chunks.append(String(character)); currentRun?.lastKey = now
                currentRun?.characterCount += 1
                if (currentRun?.characterCount ?? 0) >= 2_000 { finishRun() }
            }
        case .paste:
            if currentRun == nil { currentRun = Run(context: context, started: now, lastKey: now) }
            currentRun?.chunks.append("‹pasted›"); currentRun?.pasteCount += 1; currentRun?.lastKey = now
            currentRun?.characterCount += "‹pasted›".count
            if (currentRun?.characterCount ?? 0) >= 2_000 { finishRun() }
        case .ime:
            if currentRun?.chunks.isEmpty == false { finishRun() }
            if currentRun == nil { currentRun = Run(context: context, started: now, lastKey: now) }
            currentRun?.imeCount += 1; currentRun?.lastKey = now
        }
        idleTask?.cancel()
        idleTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let self, readableContext() != nil else { return }; finishRun()
        }
    }
    private func finishRun() {
        guard let run = currentRun else { return }; currentRun = nil; idleTask?.cancel(); idleTask = nil
        guard run.imeCount > 0 || !run.chunks.isEmpty else { return }
        let first = LocalRedactor.firstPass(run.text)
        // Queue the stage-one value, not its raw source. Keep metadata and counts only.
        var metadata = run; metadata.chunks = []
        if pending.count >= 20 { pending.removeFirst() }
        pending.append(.init(run: metadata, firstPass: first, policy: settings, generation: generation)); startWork()
    }
    private func valid(_ item: Pending) -> Bool {
        guard running, !Task.isCancelled else { return false }
        var original = item.policy; original.deferProcessing = settings.deferProcessing
        return generation == item.generation && settings == original && !settings.deferProcessing &&
        settings.permits(item.run.context) && modelAvailable() && source.hasPermission && !secureInput() &&
        context().map { !$0.isPrivate && !$0.isLocked && !$0.secureInput && settings.permits($0) } == true
    }
    private func startWork() {
        guard work == nil, !settings.deferProcessing, !pending.isEmpty else { return }
        let id = UUID(); workID = id
        work = Task(priority: .utility) { @MainActor [weak self] in
            guard let self else { return }
            defer { if workID == id { work = nil; workID = nil } }
            while !pending.isEmpty, !Task.isCancelled {
                let item = pending.removeFirst()
                guard valid(item) else { continue }
                let payload: Redacted<JournalPayload>
                if item.run.imeCount > 0 {
                    let app = LocalRedactor.firstPass(item.run.context.appName)
                    payload = .init(.init(description: "Typed in " + app.value,
                        details: ["appName": app.value, "inputMethod": "ime", "keyCount": String(item.run.imeCount), "words_not_kept": "inputMethod"]))
                } else {
                    guard let safe = await processor.redact(words: item.firstPass, app: item.run.context.appName) else {
                        if valid(item) { lastError = "Some typing wasn't kept because Zeus couldn't safely remove private details." }
                        continue
                    }
                    guard valid(item) else { continue }
                    let topic = await summarizer.summarize(safe)
                    guard valid(item) else { continue }
                    var result = topic.value
                    result.text = item.policy.words != .none && safe.wordCount >= 3 ? safe.words.value : nil
                    result.details["words_not_kept"] = result.text == nil ? (safe.wordCount < 3 ? "shortRun" : "setting") : ""
                    if result.text != nil { result.details["words_expires"] = String(item.run.started.addingTimeInterval(Double(item.policy.words.hours) * 3600).timeIntervalSince1970) }
                    result.details["pasteCount"] = String(item.run.pasteCount)
                    payload = .init(result, report: safe.words.report)
                }
                guard valid(item) else { continue }
                var value = payload.value; value.details["run_id"] = item.run.id
                let topicDays = [7, 30, 90].contains(item.policy.topicRetentionDays) ? item.policy.topicRetentionDays : 30
                value.details["topic_expires"] = String(item.run.started.addingTimeInterval(Double(topicDays) * 86400).timeIntervalSince1970)
                do {
                    try journal.append(.init(id: item.run.id, time: item.run.started, level: .typed, app: item.run.context.bundleID,
                        kind: .typedText, payload: .init(value, report: payload.report)))
                    lastError = nil
                } catch { lastError = "Zeus couldn't keep this stretch of typing." }
            }
        }
    }
}
