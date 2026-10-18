import Foundation
import Observation
import ZeusLink
import ZeusProtocol

/// The MainActor boundary between app models, bridge tools and durable agent deliveries.
/// UI code talks only to AgentMessaging and CardStoring; connectors never mutate UI models.
@MainActor
@Observable
final class ZeusRuntime: AgentMessaging, BridgeServerDelegate {
    private(set) var sessions: [ConnectedSession] = []
    private(set) var userMessageDeliveries: [UserMessageDelivery] = []
    @ObservationIgnored var recoveredUserMessageIDs: Set<String> = []
    var deliveryIssue: DeliveryIssue?
    /// Ephemeral response activity for the UI's thread row and CONTRACT §7 rule 3b.
    private(set) var assistantActivity: AssistantActivity?
    @ObservationIgnored var activityRecords: [String: ActivityRecord] = [:]
    @ObservationIgnored var activityTokens: [String: UUID] = [:]
    @ObservationIgnored var activityDeliveryIDs: Set<ActivityDeliveryKey> = []
    @ObservationIgnored var activityEarlyAcknowledgments: [String: Date] = [:]
    @ObservationIgnored var activityOrder = 0
    /// Sessions whose managed/selected-own screen showed "working" since their current activity started (a later idle screen ends it).
    @ObservationIgnored var activityWorkingSeen: Set<String> = []
    @ObservationIgnored let ownScreenReader: any OwnSessionScreenReading
    @ObservationIgnored var ownScreenTask: Task<Void, Never>?
    @ObservationIgnored var ownScreenSamplingLease: OwnScreenLease?
    @ObservationIgnored var activityTimer: Task<Void, Never>?
    @ObservationIgnored let quietHours: (Date) -> Bool
    @ObservationIgnored let appControl: any AppControlling
    @ObservationIgnored let learnings: any LearningsProviding
    @ObservationIgnored let learningRules: (any RulesStore)?
    @ObservationIgnored let learningJournal: (any JournalStore)?
    @ObservationIgnored let messageRatings: MessageRatingStore?
    @ObservationIgnored let ratingSimilarity: any MessageSimilarityComparing
    @ObservationIgnored var ratingSignalTimer: Task<Void, Never>?
    @ObservationIgnored var ratingDeliveryTask: Task<Void, Never>?
    @ObservationIgnored var ratingRetryTask: Task<Void, Never>?
    @ObservationIgnored var ratingExportVersion: UUID?
    @ObservationIgnored var onShowMuted: (([String]) -> Void)?
    var ratingError: String?
    @ObservationIgnored let learningFolder: (any LearningFolderRecording)?
    @ObservationIgnored let learningRedactor: (any Redactor)?
    @ObservationIgnored let learningContext: () -> LearningContext
    @ObservationIgnored let reflectionEnabled: () -> Bool
    @ObservationIgnored let learningCalendar: Calendar
    @ObservationIgnored let morningBriefSettings: MorningBriefSettings?
    @ObservationIgnored let morningBriefLevels: () -> Set<JournalLevel>
    @ObservationIgnored var proactiveState: ProactiveState?
    @ObservationIgnored var proactiveActivityAt: Date?
    var learningInterruptionHold = false
    var learningError: String?
    var pendingLearningDeliveries: [PendingLearningDelivery] = []
    var deliveryHolds: [DeliveryHold] = []
    @ObservationIgnored var deliveryHoldEpisodes: [String: DeliveryHold] = [:]
    @ObservationIgnored var journalAccessPolicy: () -> JournalAccessPolicy = { .init() }
    @ObservationIgnored var onViewJournalAnswer: ((String) -> Void)?
    @ObservationIgnored var journalCalls: [Date] = []
    @ObservationIgnored var journalAnswerReceipts: [String: (ToolResult, String, UInt64, Bool)] = [:]
    @ObservationIgnored var journalNoticeWindow: (Date, String, Int)?
    @ObservationIgnored var onReviewRule: ((String) -> Void)?
    /// ST1: opens Settings › Assistant ("Change" / "Open Settings" on admission lines).
    @ObservationIgnored var onOpenAssistantSettings: (() -> Void)?
    /// ST1: refused-session lines already posted, one per session per day.
    @ObservationIgnored var admissionNoticeIDs: Set<String> = []
    @ObservationIgnored var onLearningHoldCleared: (([String]) -> Void)?
    @ObservationIgnored var learningHeldIDs: [String] = []
    @ObservationIgnored var learningCardRules: [String: [String]] = [:]
    @ObservationIgnored var learningTimer: Task<Void, Never>?
    @ObservationIgnored var reflectionTask: Task<Void, Never>?
    @ObservationIgnored var learningCatchUpPending = true
    @ObservationIgnored var learningObservationToken = UUID()
    @ObservationIgnored var erasedLearningDeliveryIDs = Set<String>()
    @ObservationIgnored var checkedUpdateVersions: [String: Set<String>] = [:]
    @ObservationIgnored var pendingUpdateErrors: [String: String] = [:]
    @ObservationIgnored var installingSessions: Set<String> = []
    @ObservationIgnored var activeToolCalls: [String: Int] = [:]
    @ObservationIgnored var appQuestionIDs: Set<String> = []
    @ObservationIgnored var disconnectedAt: [String: Date] = [:]
    @ObservationIgnored var sendTokens: [String: UUID] = [:]
    @ObservationIgnored var knownIssueIDs: Set<String> = []
    @ObservationIgnored let cards: any CardStoring
    @ObservationIgnored let status: any AvatarStatusControlling
    @ObservationIgnored let characters: any CharacterControlling
    @ObservationIgnored let routing: any AgentRoutingSettings
    @ObservationIgnored let clock: any RuntimeClock
    @ObservationIgnored let socketPath: String
    @ObservationIgnored let ledgerURL: URL
    @ObservationIgnored let connectors: [any DeliveryConnector]
    @ObservationIgnored var ledger: DeliveryLedger?
    @ObservationIgnored var running = false
    @ObservationIgnored var server: BridgeServer?
    @ObservationIgnored var bridges: [String: BridgeSession] = [:]
    @ObservationIgnored var generation = UUID()
    @ObservationIgnored var retryTimer: Task<Void, Never>?
    @ObservationIgnored var deferredSends: [String: Date] = [:]
    @ObservationIgnored var sends: [String: Task<MessageSendResult, Never>] = [:]
    @ObservationIgnored var storageProblem: String?
    var managedDraftAlertCardID: String?
    var managedDraftWaiting = false
    var managedDraftCancellation: ManagedDraftCancellation?
    @ObservationIgnored var managedDraftEpisode: ManagedDraftEpisode?
    @ObservationIgnored var recoveredDraftCardID: String?
    @ObservationIgnored var handledResponses: Set<String> = []
    @ObservationIgnored var completedResponseIDs: [String] = []
    @ObservationIgnored var contextReceiptIDs: Set<String> = []
    @ObservationIgnored var unsaved: [DeliveryRecord] = []
    @ObservationIgnored var responseJournal: ResponseJournal?
    @ObservationIgnored var awaitingAnswerReceipt: Set<String> = []
    struct AnswerActivityReceipt {
        let sessionKey: String
        let deliveryID: String
        let token: UUID?
        let sessionID: UUID?
        let receivedAt: Date
    }
    @ObservationIgnored var answerActivityReceipts: [String: AnswerActivityReceipt] = [:]
    @ObservationIgnored var managedBlockedCardID: String?
    @ObservationIgnored var managedChannelReady: Set<String> = []
    @ObservationIgnored var managedChannelProbes: [String: String] = [:]
    @ObservationIgnored var managedProbeTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored let managedController: ManagedSessionController
    @ObservationIgnored let targetIsDead: (String) -> Bool

    struct AskWaiter {
        let sessionKey: String
        let deadline: Date
        let continuation: CheckedContinuation<ToolResult, Never>
        let timer: Task<Void, Never>
        let deferResultCommit: Bool
        let deliveryID: String
        let activityToken: UUID?
        let sessionID: UUID?
    }
    @ObservationIgnored var waiters: [String: AskWaiter] = [:]

    /// `quietHours` must use the app's quiet-hours settings at the supplied date;
    /// it is queried when each result returns, including delayed answers and errors.
    /// Default arguments preserve the contract composition initializer; overrides isolate tests.
    init(cards: any CardStoring, status: any AvatarStatusControlling,
         characters: any CharacterControlling, routing: any AgentRoutingSettings,
         clock: any RuntimeClock = SystemRuntimeClock(), socketPath: String = ZeusPaths.bridgeSocket.path,
         ledgerURL: URL = ZeusPaths.deliveries, connectors: [any DeliveryConnector] = [ChannelDeliveryConnector(), TmuxConnector(), OpenCodeConnector()],
         quietHours: @escaping (Date) -> Bool = { _ in false },
         targetIsDead: @escaping (String) -> Bool = AgentSessionLiveness.isDead,
         managedController: ManagedSessionController? = nil,
         appControl: (any AppControlling)? = nil, learnings: (any LearningsProviding)? = nil,
         ownScreenReader: any OwnSessionScreenReading = OwnSessionScreenReader(),
         rules: (any RulesStore)? = nil, journal: (any JournalStore)? = nil, redactor: (any Redactor)? = nil,
         learningFolder: (any LearningFolderRecording)? = nil,
         messageRatings: MessageRatingStore? = nil, ratingSimilarity: any MessageSimilarityComparing = LocalMessageSimilarity(),
         learningContext: @escaping () -> LearningContext = { .init() },
         reflectionEnabled: @escaping () -> Bool = { false }, learningCalendar: Calendar = .current,
         morningBriefSettings: MorningBriefSettings? = nil, morningBriefLevels: @escaping () -> Set<JournalLevel> = { [] }) {
        self.morningBriefSettings = morningBriefSettings; self.morningBriefLevels = morningBriefLevels
        self.messageRatings = messageRatings; self.ratingSimilarity = ratingSimilarity
        self.learningFolder = learningFolder
        self.learningRules = rules; self.learningJournal = journal; self.learningRedactor = redactor
        self.learningContext = learningContext; self.reflectionEnabled = reflectionEnabled; self.learningCalendar = learningCalendar
        self.ownScreenReader = ownScreenReader
        self.cards = cards; self.status = status; self.characters = characters; self.routing = routing
        self.appControl = appControl ?? UnavailableAppControl()
        self.learnings = learnings ?? EmptyLearnings()
        self.managedController = managedController ?? ManagedSessionController(configuration: { routing.managedSession },
            stateURL: ledgerURL.deletingLastPathComponent().appendingPathComponent("managed-session.json"),
            bridge: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/zeus-mcp"), bridgeSocket: socketPath, clock: clock)
        self.clock = clock; self.socketPath = socketPath; self.ledgerURL = ledgerURL; self.connectors = connectors; self.quietHours = quietHours; self.targetIsDead = targetIsDead
    }

    /// Creates local directories, loads delivery state and starts the socket listener.
    /// A corrupt ledger or occupied socket throws without replacing existing state.
    func start() throws {
        guard !running else { return }
        if socketPath == ZeusPaths.bridgeSocket.path || ledgerURL == ZeusPaths.deliveries { try ZeusPaths.createDirectories() }
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: socketPath).deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ledgerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let loaded = try DeliveryLedger(location: ledgerURL)
        proactiveState = try ProactiveState(url: ledgerURL.deletingLastPathComponent().appendingPathComponent("proactive-state.json"))
        let journal = try ResponseJournal(location: ledgerURL.deletingLastPathComponent().appendingPathComponent("response-intents.json"))
        // Import open cards from pre-journal installations without replaying ambiguous
        // historical answers that may already have been delivered synchronously.
        for card in (cards as? any CardPersistenceReporting)?.persistedCards ?? []
            where !card.id.hasPrefix(Self.managedCardPrefix) && card.status == .open && card.sessionKey != nil && (!card.options.isEmpty || card.input != nil) {
            try journal.prepare(card.id)
        }
        let listener = BridgeServer(socketPath: socketPath)
        try listener.start(delegate: self)
        do { try loaded.prepareLegacyUserMessages(); try loaded.preparePointerDeliveries() }
        catch { listener.stop(); throw error }
        recoveredUserMessageIDs = Set(loaded.records.filter { $0.delivery.kind == .userMessage }.map { $0.delivery.id })
        let localCards = ((cards as? any CardPersistenceReporting)?.persistedCards ?? []).filter { $0.id.hasPrefix(Self.managedCardPrefix) && $0.status == .open }
        let recoveredDrafts = localCards.filter { $0.id.hasPrefix(Self.managedDraftPrefix) }
        recoveredDraftCardID = recoveredDrafts.last?.id
        for card in recoveredDrafts.dropLast() { resolveManagedCard(card.id, end: .unavailable) }
        let recoveredBlocks = localCards.filter { !$0.id.hasPrefix(Self.managedDraftPrefix) }
        managedBlockedCardID = recoveredBlocks.last?.id
        for card in recoveredBlocks.dropLast() { resolveManagedCard(card.id) }
        loaded.onChange = { [weak self] records in self?.publishUserMessageDeliveries(records); self?.publishPendingLearnings(records); self?.syncLearningFolder() }
        ledger = loaded; responseJournal = journal; server = listener; running = true; generation = UUID()
        appQuestionIDs = Set(((cards as? any CardPersistenceReporting)?.persistedCards ?? [])
            .filter { $0.kind == .question && $0.status == .open }.map(\.id))
        learnings.onNewLearning = { [weak self] learning in self?.notifyLearning(learning) }
        expireStaleLearningDeliveries()
        syncLearningFolder()
        learningFolder?.start(learnings: learnings)
        startLearning()
        messageRatings?.onChange = { [weak self] in self?.scheduleRatingDelivery(); self?.scheduleRatingSuggestions() }
        scheduleRatingDelivery(); scheduleRatingSuggestions()
        observeLearningAvailability()
        publishUserMessageDeliveries(loaded.records)
        contextReceiptIDs.removeAll()
        for record in loaded.records where record.transportDeliveredAt != nil || record.delivery.ackedAt != nil {
            recordContextDeliveryReceipt(id: record.delivery.id)
            recordReflectionReceipt(id: record.delivery.id)
        }
        handledResponses.formUnion(loaded.records.compactMap { $0.delivery.cardID })
        (cards as? any LocalCardActionHandling)?.localActionHandler = { [weak self] card, response in
            self?.handleManagedAction(card, response: response) ?? false
        }
        cards.responseHandler = { [weak self] card, response in self?.receivedResponse(card, response: response) }
        retainRuntimeHistory()
        processDueDeliveries()
        managedController.onChange = { [weak self] in
            guard let self, self.running else { return }
            self.syncLearningFolder()
            self.managedController.considerSessions(self.sessions)
            self.noteManagedScreenActivity(); self.reconcileOwnScreenSampling(); self.updateManagedPresentation(); self.probeManagedChannel()
            self.bindWaitingUserMessages(); self.processDueDeliveries(); self.proactiveSettingsDidChange()
        }
        managedController.settingsApplicationAllowed = { [weak self] in
            guard let self, self.running, self.sends.isEmpty else { return false }
            let key = self.managedController.sessionKey
            return !(self.ledger?.records ?? []).contains {
                $0.isPending && $0.delivery.sessionKey == key && ($0.delivery.meta["tmux_paste_destination"] != nil
                    || ($0.delivery.meta["managed_channel_sent_at"] != nil && $0.delivery.meta["managed_channel_fallback"] != "true"))
            }
        }
        managedController.activate()
        if !managedController.enabled { updateManagedPresentation() }
        observeRouting()
    }

    /// Stops transport and timers. Open asks become pending; saved deliveries survive the next start.
    func stop() {
        // Preserve the actual shutdown time, not the age of an already-pending reply,
        // when the next process decides whether the 60-second grace period elapsed.
        for session in sessions { disconnectedAt[session.sessionKey] = clock.now }
        running = false
        messageRatings?.onChange = nil
        ratingSignalTimer?.cancel(); ratingSignalTimer = nil
        ratingDeliveryTask?.cancel(); ratingDeliveryTask = nil
        ratingRetryTask?.cancel(); ratingRetryTask = nil
        stopLearning()
        learningFolder?.stop()
        learnings.onNewLearning = nil
        checkedUpdateVersions.removeAll(); pendingUpdateErrors.removeAll(); installingSessions.removeAll(); activeToolCalls.removeAll()
        managedController.shutdown()
        managedDraftAlertCardID = nil; managedDraftWaiting = false; managedDraftCancellation = nil; managedDraftEpisode = nil
        (status as? any ManagedBlockingPresenting)?.setManagedBlock(nil)
        for task in managedProbeTasks.values { task.cancel() }
        managedProbeTasks.removeAll(); managedChannelProbes.removeAll(); managedChannelReady.removeAll()
        running = false; generation = UUID()
        resetAssistantActivity()
        server?.stop(); server = nil
        retryTimer?.cancel(); retryTimer = nil
        for task in sends.values { task.cancel() }
        sends.removeAll(); sendTokens.removeAll(); deferredSends.removeAll()
        for id in Array(waiters.keys) { finishWaiter(id: id, result: pendingResult(id)) }
        cards.responseHandler = nil
        (cards as? any LocalCardActionHandling)?.localActionHandler = nil
        awaitingAnswerReceipt.removeAll(); answerActivityReceipts.removeAll()
        sessions.removeAll(); bridges.removeAll()
        updateDisconnectedTargets()
    }

    /// Legacy convenience; UI code uses the correlated overload with a persisted ID.
    func sendUserMessage(_ text: String) async -> MessageSendResult {
        await sendUserMessage(text, deliveryID: UserMessageDelivery.makeID())
    }

    /// Saves one message once. Repeating a saved ID observes/coalesces existing work;
    /// only Retry now requests redelivery. Failed storage leaves the ID reusable.
    func sendUserMessage(_ text: String, deliveryID: String) async -> MessageSendResult {
        guard running, let ledger else { return .failed(reason: "Zeus runtime isn't running.") }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .failed(reason: "Enter a message first.") }
        guard !deliveryID.isEmpty, deliveryID.utf8.count <= 128,
              deliveryID.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 || $0 == 45 }) else {
            return .failed(reason: "Invalid delivery ID. Allocate it once with UserMessageDelivery.makeID().")
        }
        if let existing = ledger.record(id: deliveryID) {
            guard existing.delivery.kind == .userMessage, userMessageText(existing) == text else {
                return .failed(reason: "This delivery ID belongs to a different message. Create a new ID for new text.")
            }
            if existing.discardedAt != nil { return .failed(reason: "This message was discarded. Create a new message to send it again.") }
            if let task = sends[deliveryID] { return await task.value }
            return existing.delivery.ackedAt != nil || existing.transportDeliveredAt != nil
                ? .delivered : .queued(reason: existing.queueReason ?? "Waiting for your assistant.")
        }
        let target = assistantTarget
        var delivery = Delivery(id: deliveryID, kind: .userMessage, sessionKey: target ?? "", content: "Message from the user: \(text)", createdAt: clock.now)
        delivery.meta = ["kind": "userMessage", "delivery_id": delivery.id]
        do {
            try ledger.insert(.init(delivery: delivery, userText: text, awaitingAssistant: target == nil ? true : nil,
                                    queueReason: "Waiting for your assistant to connect.", stateUpdatedAt: clock.now))
            if unsaved.isEmpty { storageProblem = nil }
        } catch {
            storageProblem = "Couldn't save the message: \(error.localizedDescription)"; refreshProblem()
            return .failed(reason: "Zeus couldn't save your message. Check that your Mac has free disk space, then try again.")
        }
        refreshManagedDraftAlert()
        refreshLearningDeliveryPresentation()
        guard let task = beginSend(id: delivery.id) else {
            refreshQueueReasons(); refreshProblem(); scheduleRetry()
            return .queued(reason: ledger.record(id: delivery.id)?.queueReason ?? "Waiting for your assistant to connect.")
        }
        return await task.value
    }

    func bridgeDidConnect(_ session: BridgeSession) {
        let hello = session.hello
        registerSession(.init(id: session.id, sessionKey: session.sessionKey, agent: hello.agent, cwd: hello.cwd,
                              clientName: hello.client.name, supportsChannel: hello.capabilities.channel,
                              tmuxPane: hello.tmuxPane, connectedAt: clock.now, tmuxSocketPath: hello.tmuxSocketPath), bridge: session)
    }
    func bridgeDidDisconnect(_ session: BridgeSession) {
        // A process reuses its bridgeID after socket reconnects. Ignore a delayed old
        // connection callback even when the new connection has that same UUID.
        guard bridges[session.sessionKey] === session else { return }
        unregisterSession(id: session.id, sessionKey: session.sessionKey)
    }
    func bridge(_ session: BridgeSession, callTool name: String, arguments: JSONValue) async -> ToolResult {
        await callTool(name, arguments: arguments, sessionKey: session.sessionKey, deferResultCommit: true)
    }

    func bridge(_ session: BridgeSession, finishedTool name: String, result: ToolResult, written: Bool) {
        guard running else { return }
        if name == "zeus_get_journal" {
            if written, !result.isError { recordJournalAnswerReceipt(result, sessionKey: session.sessionKey) }
            else if case .string(let id) = result.structured?["answer_id"] { journalAnswerReceipts.removeValue(forKey: id) }
        }
        if name == "zeus_get_learnings", written, !result.isError,
           case .array(let items) = result.structured?["learnings"], case .string(let id) = items.last?["id"] {
            if !learningWasErased(id) { learnings.markLearningsRead(through: id) }
            recordLearningToolReceipts(items, sessionKey: session.sessionKey)
        }
        if name == "zeus_get_responses", written, case .array(let items) = result.structured?["items"] {
            let ids = Set(items.compactMap { item -> String? in
                if case .string(let id) = item["delivery_id"] { return id }; return nil
            })
            do { _ = try acknowledge(ids: ids, sessionKey: session.sessionKey) }
            catch { storageProblem = "Couldn't save polling acknowledgment: \(error.localizedDescription)" }
        }
        if name == "zeus_ask", result.structured?["status"] == "answered" || result.structured?["status"] == "skipped", case .string(let id) = result.structured?["card_id"] {
            awaitingAnswerReceipt.remove(id)
            let receipt = answerActivityReceipts.removeValue(forKey: id)
            if written {
                do {
                    try responseJournal?.complete(id)
                    emitContextDeliveryReceipt(deliveryID: receipt?.deliveryID ?? "answer_" + id, cardID: id,
                        sessionKey: session.sessionKey, at: clock.now)
                    if let receipt {
                        noteDeliveredActivity(sessionKey: receipt.sessionKey, deliveryID: receipt.deliveryID,
                            token: receipt.token, sessionID: receipt.sessionID, inputStartedAt: receipt.receivedAt)
                    }
                } catch { storageProblem = "Couldn't commit the answer receipt: \(error.localizedDescription)" }
            } else {
                handledResponses.remove(id)
                // A response posted before a lost receipt must also suppress activity
                // from replaying this answer through a connector later.
                if let receipt, receipt.token != activityTokens[receipt.sessionKey] {
                    activityDeliveryIDs.insert(.init(sessionKey: receipt.sessionKey, deliveryID: receipt.deliveryID))
                }
            }
        }
        processDueDeliveries()
    }

    /// Central connection registration also supports connector-backed integration tests.
    func registerSession(_ session: ConnectedSession, bridge: BridgeSession? = nil) {
        guard running else { return }
        endAssistantActivity(sessionKey: session.sessionKey)
        sessions.removeAll { $0.sessionKey == session.sessionKey }
        sessions.insert(session, at: 0)
        bridges[session.sessionKey] = bridge
        reconcileOwnScreenSampling()
        managedController.considerSessions(sessions)
        probeManagedChannel()
        disconnectedAt.removeValue(forKey: session.sessionKey)
        updateDisconnectedTargets()
        adoptAutoAssistantIfNeeded()
        bindWaitingUserMessages()
        for record in ledger?.records ?? [] where record.delivery.sessionKey == session.sessionKey && record.isPending
            && (record.delivery.failedAt == nil || record.delivery.meta["tmux_paste_destination"] != nil) {
            let id = record.delivery.id
            if let active = sends[id] {
                let token = generation
                Task { [weak self] in
                    _ = await active.value
                    guard let self, self.running, self.generation == token, self.sessions.first(where: { $0.sessionKey == session.sessionKey })?.id == session.id else { return }
                    _ = self.beginSend(id: id)
                }
            } else { _ = beginSend(id: id) }
        }
        processDueDeliveries()
        learningContextDidChange()
    }
    func unregisterSession(id: UUID, sessionKey: String) {
        guard sessions.first(where: { $0.sessionKey == sessionKey })?.id == id else { return }
        sessions.removeAll { $0.id == id }; bridges.removeValue(forKey: sessionKey)
        endAssistantActivity(sessionKey: sessionKey)
        activityTokens.removeValue(forKey: sessionKey)
        disconnectedAt[sessionKey] = clock.now
        updateDisconnectedTargets()
        bindWaitingUserMessages()
        for record in ledger?.records ?? [] where record.delivery.sessionKey == sessionKey { sends[record.delivery.id]?.cancel() }
        for (cardID, waiter) in waiters where waiter.sessionKey == sessionKey { finishWaiter(id: cardID, result: pendingResult(cardID)) }
        refreshProblem(); scheduleRetry()
    }

    /// Handles a recorded UI answer once. The clock comparison makes timeout ordering deterministic.
    func receivedResponse(_ card: Card, response: CardResponse) {
        guard running else { return }
        if handleManagedAction(card, response: response) { return }
        guard handledResponses.insert(card.id).inserted else { return }
        recordRuleAnswer(card, response: response)
        if let waiter = waiters[card.id] {
            if clock.now < waiter.deadline {
                if waiter.deferResultCommit {
                    awaitingAnswerReceipt.insert(card.id)
                } else {
                    do { try responseJournal?.complete(card.id) }
                    catch {
                        finishWaiter(id: card.id, result: pendingResult(card.id))
                        enqueueResponse(card, response: response); return
                    }
                }
                finishWaiter(id: card.id, result: answeredResult(card.id, response: response))
                return
            }
            finishWaiter(id: card.id, result: pendingResult(card.id))
        }
        enqueueResponse(card, response: response)
        processDueDeliveries()
    }

    func enqueueResponse(_ card: Card, response: CardResponse) {
        // Demo cards have no originating agent and are recorded only in UI history.
        guard let target = card.sessionKey else { return }
        var delivery = Delivery(kind: .reply, cardID: card.id, sessionKey: target,
                                content: response.skipped ? "The user skipped \"\(card.title ?? card.body)\"."
                                    : "Reply to \"\(card.title ?? card.body)\": \(response.summary)", createdAt: clock.now)
        if let intent = responseJournal?.intents.first(where: { $0.cardID == card.id }) { delivery.id = intent.deliveryID }
        delivery.meta = ["kind": response.skipped ? "skipped" : "reply", "delivery_id": delivery.id, "card_id": card.id]
        if !response.skipped, let option = response.optionID { delivery.meta["option_id"] = option }
        let record = DeliveryRecord(delivery: delivery, response: response, disconnectedAt: sessions.contains(where: { $0.sessionKey == target }) ? nil : (disconnectedAt[target] ?? clock.now))
        do {
            if ledger?.record(id: record.delivery.id) == nil { try ledger?.insert(record) }
            try responseJournal?.complete(card.id)
        }
        catch {
            // A response callback cannot throw back into the UI. Retain it for a disk retry,
            // never send unsaved input, and expose the persistence problem visibly.
            if ledger?.record(id: record.delivery.id) == nil && !unsaved.contains(where: { $0.delivery.id == record.delivery.id }) { unsaved.append(record) }; storageProblem = "Couldn't save the response: \(error.localizedDescription)"
        }
        refreshProblem(); scheduleRetry()
    }

    func finishWaiter(id: String, result: ToolResult) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        if result.structured?["status"] == "answered" || result.structured?["status"] == "skipped" {
            completedResponseIDs.append(id)
            if completedResponseIDs.count > 500 { completedResponseIDs.removeFirst(completedResponseIDs.count - 500) }
            if waiter.deferResultCommit {
                answerActivityReceipts[id] = .init(sessionKey: waiter.sessionKey, deliveryID: waiter.deliveryID,
                                                 token: waiter.activityToken, sessionID: waiter.sessionID, receivedAt: clock.now)
            } else {
                noteDeliveredActivity(sessionKey: waiter.sessionKey, deliveryID: waiter.deliveryID,
                    token: waiter.activityToken, sessionID: waiter.sessionID)
            }
        }
        waiter.timer.cancel(); waiter.continuation.resume(returning: result)
    }
    func publishAssistantActivity(_ value: AssistantActivity?) {
        if assistantActivity != value { assistantActivity = value }
    }
    func setUserMessageDeliveries(_ value: [UserMessageDelivery]) {
        if userMessageDeliveries != value { userMessageDeliveries = value }
    }
    func pendingResult(_ id: String) -> ToolResult { result(["status": "pending", "card_id": .string(id)]) }
    func answeredResult(_ id: String, response: CardResponse) -> ToolResult {
        if response.skipped { return result(["status": "skipped", "card_id": .string(id)]) }
        var json: [String: JSONValue] = ["status": "answered", "card_id": .string(id)]
        if let value = response.optionID { json["option_id"] = .string(value) }
        if let value = response.optionLabel { json["option_label"] = .string(value) }
        if let value = response.text { json["text"] = .string(value) }
        return result(.object(json))
    }
    func result(_ value: JSONValue) -> ToolResult {
        var value = value
        if quietHours(clock.now) || learningInterruptionHold, case .object(var fields) = value {
            fields["quiet"] = true; value = .object(fields)
        }
        do { return try ToolResult(structured: value) }
        catch { return ToolResult(text: "Couldn't encode Zeus result: \(error.localizedDescription)", isError: true) }
    }
}
