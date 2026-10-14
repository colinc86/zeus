import AppKit
import Observation
import SwiftUI
import ZeusProtocol
import ZeusDesign
import ZeusSprites

@MainActor
private final class CompanionPanel: NSPanel {
    var acceptsKeys = false
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { acceptsKeys }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

@MainActor
@Observable
final class ShellController: NSObject, NSWindowDelegate, NSPopoverDelegate {
    let cards: CardStore
    let status: AvatarStatusModel
    let settings: AppSettings
    let cardPanelState = ConversationPanelState()
    let messaging = AgentMessagingHub()
    let visibility: AvatarVisibilityModel
    let hotKey = GlobalHotKey()
    let login = LoginItemModel()
    let updater = UpdaterService()
    @ObservationIgnored lazy var appControl = AppControlModel(settings: settings, visibility: visibility, updater: updater, surface: self)
    let settingsNavigation = SettingsNavigation()
    let peek: PeekModel
    let peekPanelState = PeekPanelState()
    let conversation: ConversationModel
    let testMessage: ComposeModel
    let managed: ManagedAssistantModel
    @ObservationIgnored private var managedUpdates: ManagedAgentUpdateModel?
    /// "Learn from me" (L1, CONTRACT §13). Its `learnings` is the runtime's `LearningsProviding`.
    let learn: LearnFromMe
    private(set) var isVisible = false
    /// The composition point can set this when ZeusRuntime.start() fails.
    var runtimeError: String? { didSet { messaging.startupError = runtimeError } }
    private let defaults: UserDefaults
    private let avatar = CompanionPanel(contentRect: CGRect(x: 0, y: 0, width: 96, height: 112),
                                         styleMask: [.borderless, .nonactivatingPanel],
                                         backing: .buffered, defer: false)
    private let card = CompanionPanel(contentRect: CGRect(x: 0, y: 0, width: 400, height: 500),
                                       styleMask: [.borderless, .nonactivatingPanel],
                                       backing: .buffered, defer: false)
    private let peekPanel = CompanionPanel(contentRect: CGRect(x: 0, y: 0, width: 280, height: 160),
                                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    let artLayout = AvatarArtLayout()
    let surfaceActivity = SurfaceActivity()
    @ObservationIgnored private var displayAsleep = false
    @ObservationIgnored private var systemAsleep = false
    @ObservationIgnored private var sessionInactive = false
    @ObservationIgnored private var screenLocked = false
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private(set) var scheduledDeadline: Date?
    private var suspended: Bool { displayAsleep || systemAsleep || sessionInactive || screenLocked }
    @ObservationIgnored private var peekExitTask: Task<Void, Never>?
    private let warning = NSPopover()
    private var openingWarning = false
    @ObservationIgnored private var draftCancellationAlert: NSAlert?
    @ObservationIgnored private var draftCancellationID: UUID?
    @ObservationIgnored private weak var draftCancellationProvider: (any ManagedDraftAlertControlling)?
    @ObservationIgnored private var closingTask: Task<Void, Never>?
    @ObservationIgnored private var keyMonitor: Any?
    private var settingsWindow: NSWindow?
    private var previousApplication: NSRunningApplication?
    private var renderedAnchorOffset = CGPoint.zero
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var popupSoundGate = PopupSoundGate()
    @ObservationIgnored private let popupSound: any PopupSoundPlaying
    @ObservationIgnored private(set) var ghost = AvatarGhostState()
    @ObservationIgnored private var avatarHovered = false
    @ObservationIgnored private var resizeFixedX: CGFloat?

    init(defaults: UserDefaults = .standard, cards: CardStore? = nil, settings: AppSettings? = nil,
         popupSound: any PopupSoundPlaying = SystemPopupSoundPlayer.shared) {
        self.defaults = defaults
        self.popupSound = popupSound
        visibility = AvatarVisibilityModel(defaults: defaults)
        let cards = cards ?? CardStore()
        let settings = settings ?? AppSettings(defaults: defaults)
        self.cards = cards
        peek = PeekModel(store: cards)
        self.settings = settings
        managed = ManagedAssistantModel(settings: settings, controller: { [weak messaging] in messaging?.runtime as? any ManagedSessionControlling })
        conversation = ConversationModel(cards: cards, messaging: messaging)
        testMessage = ComposeModel(cards: cards, messaging: messaging)
        // ZeusPaths.activity in the app; next to a test's own Characters folder otherwise, and none when a test passes no
        // folder, so tests never see the real one.
        learn = LearnFromMe(settings: LearnSettings(defaults: defaults), root: settings.userCharacterDirectory.map {
            $0 == ZeusPaths.userCharacters ? ZeusPaths.activity : $0.deletingLastPathComponent().appendingPathComponent("Activity", isDirectory: true)
        })
        status = AvatarStatusModel(cards: cards, quietHours: { [weak settings] in settings?.isQuiet(at: $0) ?? false },
                                   assistantActivity: { [weak messaging] in messaging?.assistantActivity })
        super.init()
        managed.hasPendingQuestion = { [weak cards] in cards?.hasOpenQuestion == true }
        managedUpdates = ManagedAgentUpdateModel(managed: managed, cards: cards)
        managedUpdates?.onConfirmation = { [weak self] in self?.showSettings(tab: .agent) }
        cards.onHistoryCleared = { [weak self] in
            guard let self else { return }
            self.conversation.pruneClearedHistory()
            self.peek.pruneRetainedHistory()
            self.settings.pruneSessionLabels(keeping: Set(self.cards.cards.compactMap(\.sessionKey) + self.messaging.sessions.map(\.sessionKey)))
        }
        cards.onAdd = { [weak self] newCard in self?.receivedCard(newCard) }
        learn.learnings?.onRecorded = { [weak cards] in cards?.recordNotice(.learning($0)) }
        learn.onDeleteEverything = { [weak cards] in cards?.removeNotices(kind: .learning) }
    }

    var unreadCountText: String { "\(cards.unseenCount) unread \(cards.unseenCount == 1 ? "message" : "messages")" }

    var menuStatus: String {
        if let detail = (messaging.runtime as? any ManagedDraftAlertControlling)?.managedDraftStatusDetail { return detail }
        let usual = MenuPresentation.status(state: status.state, unread: cards.unseenCount, activity: messaging.assistantActivity, sessionLabel: messaging.assistantActivity.map { settings.sessionLabels.label($0.sessionKey) })
        if managed.prioritizesMenuStatus { return managed.menuStatus(usual: usual, unread: cards.unseenCount) }
        if cards.unseenCount > 0 { return usual }
        return runtimeError ?? cards.persistenceError ?? status.deliveryProblem ?? managed.menuStatus(usual: usual, unread: cards.unseenCount)
    }

    /// Managed status and unread counts are independent; advanced mode keeps its ordinary count line.
    var menuUnreadDetail: String? { cards.unseenCount > 0 && managed.prioritizesMenuStatus ? unreadCountText : nil }
    /// Global storage/link failures remain visible alongside the managed status.
    var menuIssueDetail: String? { managed.enabled ? runtimeError ?? cards.persistenceError : nil }
    var menuAccessibilityLabel: String {
        (["Zeus"] + (managed.prioritizesMenuStatus ? [menuStatus] : []) + (cards.unseenCount > 0 ? [unreadCountText] : [])).joined(separator: " · ")
    }

    func start() {
        settings.startWatchingUserFolders()
        learn.start()
        configure(avatar)
        // Ghost mode changes only alpha; it never makes Zeus click-through.
        avatar.ignoresMouseEvents = false
        configure(card)
        configure(peekPanel)
        card.contentView = nil
        peekPanel.title = "Zeus says"
        peekPanel.contentView = PeekHostingView(rootView: PeekView(model: peek, panel: peekPanelState, settings: settings, activity: surfaceActivity,
            open: { [weak self] in self?.expandPeek($0) }))
        observePeekVisibility()
        observePeekLayoutInputs()
        avatar.title = "Zeus avatar"
        card.title = "Zeus conversation"
        card.acceptsKeys = true
        card.delegate = self
        card.onEscape = { [weak self] in
            guard let self else { return }
            if self.warning.isShown { self.warning.performClose(nil) } else { self.closeCard() }
        }
        let view = AvatarInteractionView(rootView: SpriteAvatarView(settings: settings, status: status, messaging: messaging, artLayout: artLayout, activity: surfaceActivity))
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        view.contextMenu = { [weak self] in self?.makeContextMenu() ?? NSMenu() }
        view.onWarning = { [weak self] in self?.toggleWarning() }
        view.onShowDeliveryProblem = { [weak self] in self?.showDeliveryProblem() }
        view.warningFrame = { [weak self, weak view] in
            guard let self, let view else { return .zero }
            return self.artLayout.rect.warningFrame(in: view.bounds, flipped: view.isFlipped)
        }
        view.hasWarning = { [weak self] in self?.messaging.deliveryIssue != nil }
        view.onClick = { [weak self] in self?.toggleCard() }
        view.onMove = { [weak self] point in self?.moveAvatar(to: point) }
        view.onDragEnd = { [weak self] in self?.savePosition() }
        view.onInteraction = { [weak self] in self?.noteGhostInteraction() }
        view.onHover = { [weak self] hovered in
            guard let self, self.avatarHovered != hovered else { return }
            self.avatarHovered = hovered
            self.noteGhostInteraction()
        }
        avatar.contentView = view
        warning.behavior = .transient
        warning.delegate = self
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, self.card.isKeyWindow, !self.warning.isShown else { return false }
                return self.handleConversationKey(event)
            }
            return handled ? nil : event
        }
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        resizeAvatar()
        if let x = defaults.object(forKey: "avatar.anchor.x") as? Double,
           let y = defaults.object(forKey: "avatar.anchor.y") as? Double, x.isFinite, y.isFinite {
            moveAnchor(to: CGPoint(x: x, y: y))
        } else if let x = defaults.object(forKey: "avatar.x") as? Double,
                  let y = defaults.object(forKey: "avatar.y") as? Double, x.isFinite, y.isFinite {
            // Preserve A1's origin when migrating to anchor-based persistence.
            moveAvatar(to: CGPoint(x: x, y: y))
            savePosition()
        } else { resetPosition() }
        savePosition()
        observeCharacterSettings()
        syncVisibility()
        hotKey.onPressed = { [weak self] in
            guard let self else { return }
            if ConversationLayout.hotKeyCloses(isVisible: self.cardPanelState.isVisible, isKey: self.card.isKeyWindow) { self.closeCard() }
            else { self.showTalkPanel() }
        }
        hotKey.configure(settings.talkHotKey)
        observeHotKeySettings()
        observeMenuBarIconSetting()
        observeAssistantSessionSelection()
        observeDraftCancellation()
        let managedOnboarding = settings.consumeManagedOnboarding(hasHistory: !cards.cards.isEmpty, isHidden: visibility.isHidden)
        let welcomeAdded = settings.managedSession?.enabled == true ? false : WelcomeCard.installIfNeeded(cards: cards, settings: settings)
        if (managedOnboarding || welcomeAdded) && !visibility.isHidden { showTalkPanel() }
        installLifecycleObservers()
        refreshTimedState()
        observeDeadlineInputs()
        observeGhostInputs()
        observeConversationWidth()
        refreshGhost()
        scheduleDeadline()
        refreshSurfaceActivity()
    }

    func stop() {
        stopped = true
        dismissDraftCancellation()
        settings.stopWatchingUserFolders()
        learn.stop()
        tickTask?.cancel()
        closingTask?.cancel()
        peekExitTask?.cancel()
        hotKey.stop()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }

    var isConversationMounted: Bool { card.contentView is NSHostingView<ConversationView> }

    /// Return false to leave ordinary keys, including Tab, in AppKit's native focus traversal.
    func handleConversationKey(_ event: NSEvent) -> Bool {
        let lines = (card.firstResponder as? NSTextView).map(ConversationScrollPolicy.caretLines) ?? (first: false, last: false)
        let character = event.characters?.unicodeScalars.first?.value
        let scrollKey: UInt16 = character == UInt32(NSPageUpFunctionKey) ? 116 : character == UInt32(NSPageDownFunctionKey) ? 121 : event.keyCode
        guard let command = ConversationScrollPolicy.command(keyCode: scrollKey,
            command: event.modifierFlags.contains(.command),
            otherModifiers: !event.modifierFlags.intersection([.shift, .control, .option]).isEmpty,
            composerFocused: cardPanelState.composerFocused, empty: conversation.draft.isEmpty,
            firstLine: lines.first, lastLine: lines.last) else { return false }
        cardPanelState.keyboardScroll = command
        cardPanelState.keyboardScrollRequest += 1
        return true
    }

    func mountConversation() {
        guard !isConversationMounted else { return }
        let host = ConversationHostingView(rootView: ConversationView(settings: settings, store: cards, model: conversation,
            messaging: messaging, status: status, panel: cardPanelState, activity: surfaceActivity,
            openSettings: { [weak self] in self?.showSettings(tab: .agent) },
            copySetup: { [weak self] in self?.copySetupCommands() },
            resize: { [weak self] height in
                guard let self, abs(self.cardPanelState.height - height) > 1 else { return }
                self.cardPanelState.height = height; self.positionCard()
            }, managed: managed,
            openTerminal: { [weak self] in try await self?.openConversationTerminal() },
            newConversation: { [weak self] in self?.performManagedAction(.newConversation) },
            resetWidth: { [weak self] in self?.resetConversationWidth() }))
        host.resizeHandle.onResize = { [weak self] width, edge in self?.resizeConversation(to: width, edge: edge) }
        host.resizeHandle.onReset = { [weak self] in self?.resetConversationWidth() }
        card.contentView = host
    }

    func unmountConversation() {
        resizeFixedX = nil
        card.contentView = nil
        refreshSurfaceActivity()
    }

    /// A single sleep targets the earliest real lifecycle boundary, never an idle polling tick.
    private func scheduleDeadline() {
        tickTask?.cancel()
        tickTask = nil
        let now = Date()
        scheduledDeadline = LifecycleDeadline.earliest(after: now, candidates: [
            status.nextDeadline, visibility.hiddenUntil, peek.nextDeadline,
            cards.cards.filter { $0.status == .open }.compactMap(\.expiresAt).min(),
            settings.nextQuietBoundary(after: now), ghost.nextDeadline
        ])
        guard !stopped, let deadline = scheduledDeadline else { return }
        tickTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow))) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.refreshTimedState()
            self.scheduleDeadline()
        }
    }

    private func refreshTimedState() {
        cards.expire()
        status.tick()
        visibility.tick()
        syncVisibility()
        peek.tick(suppression: peekSuppression)
        refreshGhost()
    }

    /// One-shot deadline scheduling, with no polling while faded or inhibited.
    private func refreshGhost(interaction: Bool = false) {
        let managedStatus = (messaging.runtime as? any ManagedSessionControlling)?.managedStatus
        let managedAttention: Bool
        switch managedStatus { case .starting?, .blocked?, .running(.working)?: managedAttention = true; default: managedAttention = false }
        ghost.update(at: Date(), configuration: .init(enabled: settings.fadeZeusWhenIdle, opacity: settings.idleOpacity, delay: settings.idleFadeDelay),
            inputs: .init(visible: isVisible && !visibility.isHidden && !suspended, panelOpen: cardPanelState.isVisible,
                peekVisible: peek.isVisible || peekPanel.isVisible, hovered: avatarHovered,
                questionWaiting: cards.hasOpenQuestion || managedAttention,
                assistantBusy: messaging.assistantActivity != nil || status.activity != nil), interaction: interaction)
        guard avatar.alphaValue != ghost.alpha else { return }
        let duration = AvatarGhostState.animationDuration(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || !isVisible || suspended)
        guard duration > 0 else { avatar.alphaValue = ghost.alpha; return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            avatar.animator().alphaValue = ghost.alpha
        }
    }
    func noteGhostInteraction() { refreshGhost(interaction: true); scheduleDeadline() }

    private func observeGhostInputs() {
        guard !stopped else { return }
        withObservationTracking {
            _ = settings.fadeZeusWhenIdle; _ = settings.idleOpacity; _ = settings.idleFadeDelay
            _ = cardPanelState.isVisible; _ = peek.isVisible
            _ = messaging.assistantActivity; _ = status.activity
            _ = (messaging.runtime as? any ManagedSessionControlling)?.managedStatus
            _ = cards.hasOpenQuestion
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                self.refreshGhost(); self.scheduleDeadline(); self.observeGhostInputs()
            }
        }
    }

    private func observeDeadlineInputs() {
        guard !stopped else { return }
        withObservationTracking {
            _ = cards.cards
            _ = cards.seenIDs
            _ = cards.isConversationOpen
            _ = status.nextDeadline
            _ = messaging.assistantActivity
            _ = visibility.hiddenUntil
            _ = visibility.manuallyHidden
            _ = peek.nextDeadline
            _ = settings.quietHoursEnabled
            _ = settings.quietStartHour
            _ = settings.quietEndHour
            _ = cardPanelState.isVisible
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                self.refreshTimedState()
                self.observeDeadlineInputs()
                self.scheduleDeadline()
            }
        }
    }

    #if DEBUG || ZEUS_PERFORMANCE_PROBE
    @ObservationIgnored private var ignoreOcclusionForPerformance = false
    func enableUnoccludedPerformanceProbe() {
        ignoreOcclusionForPerformance = true
        refreshSurfaceActivity()
    }
    func setPerformanceAvatarPaused(_ paused: Bool) {
        performanceAvatarPaused = paused
        refreshSurfaceActivity()
    }
    @ObservationIgnored private var performanceAvatarPaused = false
    func preparePassivePerformancePanel() {
        // The isolated benchmark must survive the human switching apps, without taking keys.
        card.acceptsKeys = false
        if ProcessInfo.processInfo.environment["ZEUS_PERF_OPAQUE_PANEL"] == "1" {
            let dark = card.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            card.backgroundColor = NSColor(ZeusPalette.for(dark ? .dark : .light,
                contrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? .increased : .standard).panel)
            card.isOpaque = true
            card.alphaValue = 1
        }
    }
    func orderPerformanceSurfacesFront() {
        // These isolated windows cannot become key; preserve the human's application focus.
        avatar.orderFrontRegardless()
        card.orderFrontRegardless()
    }
    func benchmarkScrollView() -> NSScrollView? {
        func find(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView, scroll.bounds.height > 150 { return scroll }
            return view.subviews.lazy.compactMap(find).first
        }
        return card.contentView.flatMap(find)
    }
    var performanceVisibility: String {
        "avatarOrdered=\(avatar.isVisible) avatarOcclusion=\(avatar.occlusionState.rawValue) cardOrdered=\(card.isVisible) cardOcclusion=\(card.occlusionState.rawValue) suspended=\(suspended) ignoreOcclusion=\(ignoreOcclusionForPerformance)"
    }
    #endif

    private func refreshSurfaceActivity() {
        func visible(_ window: NSWindow?) -> Bool {
            #if DEBUG || ZEUS_PERFORMANCE_PROBE
            if ignoreOcclusionForPerformance { return window?.isVisible == true }
            #endif
            return window?.isVisible == true && window?.occlusionState.contains(.visible) == true
        }
        #if DEBUG || ZEUS_PERFORMANCE_PROBE
        let avatarVisible = isVisible && visible(avatar) && !performanceAvatarPaused
        #else
        let avatarVisible = isVisible && visible(avatar)
        #endif
        surfaceActivity.update(suspended: suspended,
            avatar: avatarVisible,
            conversation: cardPanelState.isVisible && visible(card),
            peek: peek.isVisible && visible(peekPanel), settings: visible(settingsWindow))
        refreshGhost()
        scheduleDeadline()
    }

    private func installLifecycleObservers() {
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
            center.addObserver(self, selector: #selector(surfaceChanged), name: name, object: nil)
        }
        for name in [NSNotification.Name.NSSystemClockDidChange, NSNotification.Name.NSSystemTimeZoneDidChange] {
            center.addObserver(self, selector: #selector(timeChanged), name: name, object: nil)
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            workspace.addObserver(self, selector: #selector(workspaceChanged), name: name, object: nil)
        }
        let distributed = DistributedNotificationCenter.default()
        for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
            distributed.addObserver(self, selector: #selector(lockChanged), name: .init(name), object: nil)
        }
    }

    @objc private func surfaceChanged(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === avatar || window === card || window === peekPanel || window === settingsWindow else { return }
        // willClose arrives before AppKit finishes ordering the retained Settings window out.
        Task { @MainActor [weak self] in self?.refreshSurfaceActivity() }
    }

    @objc private func timeChanged(_ notification: Notification) {
        refreshTimedState()
        scheduleDeadline()
    }

    @objc private func workspaceChanged(_ notification: Notification) {
        switch notification.name {
        case NSWorkspace.screensDidSleepNotification: displayAsleep = true
        case NSWorkspace.screensDidWakeNotification: displayAsleep = false
        case NSWorkspace.willSleepNotification: systemAsleep = true
        case NSWorkspace.didWakeNotification: systemAsleep = false
        case NSWorkspace.sessionDidResignActiveNotification: sessionInactive = true
        case NSWorkspace.sessionDidBecomeActiveNotification: sessionInactive = false
        default: break
        }
        refreshTimedState()
        refreshSurfaceActivity()
        scheduleDeadline()
    }

    @objc private func lockChanged(_ notification: Notification) {
        screenLocked = notification.name.rawValue == "com.apple.screenIsLocked"
        refreshTimedState()
        refreshSurfaceActivity()
        scheduleDeadline()
    }

    private func configure(_ panel: NSPanel) {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        panel.becomesKeyOnlyIfNeeded = true
    }

    func toggleVisibility() {
        if visibility.isHidden { visibility.show() } else { visibility.hide() }
        syncVisibility()
    }

    func hide(for duration: AvatarVisibilityModel.Duration) { visibility.hide(for: duration); syncVisibility() }

    private func syncVisibility() {
        if visibility.isHidden {
            hidePeekImmediately()
            if isVisible { closeCard(); avatar.orderOut(nil); isVisible = false; avatarHovered = false }
        } else if !isVisible { avatar.orderFrontRegardless(); isVisible = true }
        refreshGhost()
        refreshSurfaceActivity()
    }

    private func showAvatar() { visibility.show(); syncVisibility() }

    private func observeHotKeySettings() {
        withObservationTracking { _ = settings.talkHotKey } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.hotKey.configure(self.settings.talkHotKey)
                self.observeHotKeySettings()
            }
        }
    }

    private func toggleCard() {
        if cardPanelState.isVisible { closeCard() } else { showAvatarConversation() }
    }

    /// Capture attention before opening/reading the viewport can clear the alert.
    func prepareAvatarConversation() -> StatusStripState.Jump? {
        let target = StatusStripState.avatarTarget(cards: .init(values: cards.cards, seen: cards.seenIDs), status: status.presentation)
        prepareTalkComposition()
        if case .question(let id) = target { conversation.rearmReplyTarget(cardID: id) }
        return target
    }
    private func showAvatarConversation() {
        noteGhostInteraction()
        let target = prepareAvatarConversation()
        guard let target else { showTalkPanel(); return }
        openConversation(at: target.cardID, focusTarget: { if case .question = target { return true }; return false }())
    }
    func openConversationTerminal() async throws {
        if managed.enabled { managed.perform(.openInTerminal); return }
        let session = settings.selectedAssistant(in: messaging.sessions)
        guard let target = ConversationTerminalTarget.make(session: session, configuredPane: settings.tmuxTarget, configuredSocket: settings.tmuxTargetSocketPath),
              let executable = TmuxExecutable.resolve() else { throw ManagedSessionError.command("The selected Terminal pane isn't available.") }
        try await ConversationTerminal().open(target, executable: executable)
    }

    /// Shared by menu, hotkey and avatar entry points, before mounting any native fields.
    func prepareTalkComposition() {
        if managed.enabled { conversation.beginPlainMessage() }
    }

    func showTalkPanel() {
        noteGhostInteraction()
        prepareTalkComposition()
        if peek.isVisible { expandPeek(.message); return }
        openConversation(at: nil)
    }

    private func openConversation(at cardID: String?, focusTarget: Bool = false) {
        hidePeekImmediately()
        peek.panelOpened()
        cardPanelState.scrollTargetCardID = cardID
        cardPanelState.focusScrollTarget = focusTarget
        cardPanelState.scrollRequest += 1
        closingTask?.cancel()
        showInteractionPanel()
        cardPanelState.focusRequest += 1
    }

    /// Keyboard/menu recovery entry point, also used by the avatar's named accessibility action.
    func showDeliveryProblem() {
        guard messaging.deliveryIssue != nil else { return }
        showAvatar()
        if !warning.isShown { toggleWarning() }
        warning.contentViewController?.view.window?.makeKey()
    }

    private func toggleWarning() {
        guard messaging.deliveryIssue != nil, let view = avatar.contentView else { return }
        if warning.isShown { warning.performClose(nil); return }
        managed.refreshAvailability()
        warning.contentViewController = NSHostingController(rootView: DeliveryWarningView(messaging: messaging, settings: settings, managed: managed,
            close: { [weak self] in self?.warning.performClose(nil) }, openSettings: { [weak self] in self?.showSettings(tab: .agent) }))
        openingWarning = true
        defer { openingWarning = false }
        warning.show(relativeTo: artLayout.rect.warningFrame(in: view.bounds, flipped: view.isFlipped), of: view, preferredEdge: .maxY)
    }

    private func showInteractionPanel() {
        showAvatar()
        if !card.isVisible { previousApplication = NSWorkspace.shared.frontmostApplication }
        mountConversation()
        positionCard()
        cardPanelState.isVisible = true
        noteGhostInteraction()
        conversation.openPanel(viewportManaged: true)
        card.makeKeyAndOrderFront(nil)
        refreshSurfaceActivity()
    }

    private func closeCard(restoreFocus: Bool = true) {
        resizeFixedX = nil
        dismissDraftCancellation()
        cardPanelState.isVisible = false
        warning.performClose(nil)
        conversation.closePanel()
        refreshSurfaceActivity()
        guard card.isVisible else { unmountConversation(); return }
        let wasKey = card.isKeyWindow
        closingTask?.cancel()
        closingTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
            guard let self, !self.cardPanelState.isVisible else { return }
            self.card.orderOut(nil)
            self.unmountConversation()
        }
        if restoreFocus && wasKey, let previousApplication,
           previousApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier,
           NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            previousApplication.activate()
        }
        previousApplication = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        guard (notification.object as? NSWindow) === card, !warning.isShown, !openingWarning, draftCancellationAlert == nil else { return }
        closeCard(restoreFocus: false)
    }

    func popoverDidClose(_ notification: Notification) {
        if cardPanelState.isVisible { card.makeKeyAndOrderFront(nil); cardPanelState.focusRequest += 1 }
    }

    private var screenRects: [CGRect] { NSScreen.screens.map(\.visibleFrame) }
    private var screenAnchor: CGPoint {
        CGPoint(x: avatar.frame.minX + renderedAnchorOffset.x, y: avatar.frame.minY + renderedAnchorOffset.y)
    }

    private func moveAvatar(to origin: CGPoint) {
        resizeFixedX = nil
        let proposed = CGRect(origin: origin, size: avatar.frame.size)
        guard let screen = PanelPlacement.screen(for: proposed, in: screenRects) else { return }
        avatar.setFrame(PanelPlacement.clamp(proposed, to: screen), display: true)
        positionCard()
        positionPeek()
    }

    private func moveAnchor(to point: CGPoint) {
        moveAvatar(to: CGPoint(x: point.x - renderedAnchorOffset.x, y: point.y - renderedAnchorOffset.y))
    }

    private func resizeAvatar() {
        let previousAnchor = screenAnchor
        if let character = settings.currentCharacter {
            artLayout.rect = AvatarArtRect(canvas: character.canvasSize, pixels: SpriteLayout.artBounds(character: character), scale: settings.pixelScale)
            renderedAnchorOffset = SpriteLayout.offset(canvas: character.canvasSize, anchor: character.anchor, scale: settings.pixelScale)
            avatar.setFrame(SpriteLayout.frame(at: previousAnchor, canvas: character.canvasSize,
                                               anchor: character.anchor, scale: settings.pixelScale), display: true)
        }
        moveAvatar(to: avatar.frame.origin)
    }

    private func observeCharacterSettings() {
        withObservationTracking {
            _ = settings.currentCharacterID
            _ = settings.currentCharacter?.fingerprint  // an edited character file can change its canvas
            _ = settings.avatarSize
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.resizeAvatar()
                self.savePosition()
                self.observeCharacterSettings()
            }
        }
    }

    /// Observe live keys even while Settings is closed; preview data never invalidates saved routing.
    func observeAssistantSessionSelection() {
        withObservationTracking {
            _ = messaging.runtime
            _ = messaging.previewEnabled
            _ = messaging.sessions
            _ = settings.assistantSessionKey
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                self.observeAssistantSessionSelection()
            }
        }
        settings.updateSessionLabels(messaging.sessions)
        if messaging.runtime != nil, !messaging.previewEnabled {
            settings.reconcileAssistantSession(with: messaging.sessions)
        }
    }

    /// Confirmation is scoped by the runtime to the deliveries present at the click.
    /// Return keeps them; closing the panel never authorizes a cancellation.
    static func makeDraftCancellationAlert(count: Int) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Cancel \(count) queued messages?"
        alert.informativeText = "These messages won't be sent. The unsent text in your assistant's Terminal will stay there."
        alert.addButton(withTitle: "Keep Messages").keyEquivalent = "\r"
        alert.addButton(withTitle: "Cancel \(count) Messages").keyEquivalent = ""
        return alert
    }

    private func observeDraftCancellation() {
        withObservationTracking {
            _ = messaging.runtime
            _ = (messaging.runtime as? any ManagedDraftAlertControlling)?.managedDraftCancellation
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                self.observeDraftCancellation()
            }
        }
        let provider = messaging.runtime as? any ManagedDraftAlertControlling
        let request = provider?.managedDraftCancellation
        guard request?.id != draftCancellationID else { return }
        dismissDraftCancellation()
        guard let provider, let request else { return }
        openConversation(at: request.cardID)
        let alert = Self.makeDraftCancellationAlert(count: request.count)
        draftCancellationAlert = alert
        draftCancellationID = request.id
        draftCancellationProvider = provider
        alert.beginSheetModal(for: card) { [weak self, weak provider] response in
            guard let self, self.draftCancellationID == request.id else { return }
            self.draftCancellationAlert = nil; self.draftCancellationID = nil; self.draftCancellationProvider = nil
            provider?.respondToDraftCancellation(id: request.id, confirmed: response == .alertSecondButtonReturn)
        }
    }

    private func dismissDraftCancellation() {
        guard let alert = draftCancellationAlert else { return }
        // Invalidate before ending the sheet: its completion must not confirm an old request.
        let id = draftCancellationID
        let provider = draftCancellationProvider
        draftCancellationAlert = nil; draftCancellationID = nil; draftCancellationProvider = nil
        card.endSheet(alert.window, returnCode: .alertFirstButtonReturn)
        if let id { provider?.respondToDraftCancellation(id: id, confirmed: false) }
    }

    private func positionCard() {
        guard let screen = PanelPlacement.screen(for: avatar.frame, in: screenRects) else { return }
        cardPanelState.screenHeight = screen.height
        let height = cardPanelState.height
        let width = ConversationWidth.clamp(settings.conversationWidth, screenWidth: screen.width)
        if width >= ConversationWidth.minimum && settings.conversationWidth != width { settings.conversationWidth = width }
        var placement = DialogPlacement.place(art: screenArtRect, anchor: screenAnchor,
                                               size: CGSize(width: width, height: height), screen: screen)
        if let fixed = resizeFixedX, let host = card.contentView as? ConversationHostingView {
            placement.frame.origin.x = ConversationWidth.origin(fixedX: fixed, width: width, edge: host.resizeHandle.edge, screen: screen)
            placement.tail.offset = min(max(((screenAnchor.x - placement.frame.minX) / 2).rounded() * 2, 16), width - 16)
        }
        cardPanelState.width = placement.frame.width
        cardPanelState.tail = placement.tail
        card.setFrame(placement.frame, display: true)
        if let host = card.contentView as? ConversationHostingView, resizeFixedX == nil {
            host.resizeEdge = ConversationWidth.edge(avatarX: screenAnchor.x, panel: placement.frame, screen: screen)
        }
    }

    func resizeConversation(to width: CGFloat, edge: ConversationWidth.Edge) {
        guard let screen = PanelPlacement.screen(for: avatar.frame, in: screenRects) else { return }
        if resizeFixedX == nil { resizeFixedX = edge == .left ? card.frame.maxX : card.frame.minX }
        if let host = card.contentView as? ConversationHostingView { host.resizeEdge = edge; host.resizeHandle.edge = edge }
        settings.conversationWidth = ConversationWidth.clamp(width, screenWidth: screen.width)
        positionCard()
    }

    func resetConversationWidth() {
        resizeFixedX = nil
        settings.conversationWidth = ConversationWidth.minimum
        positionCard()
    }

    private func observeConversationWidth() {
        guard !stopped else { return }
        withObservationTracking { _ = settings.conversationWidth } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                self.positionCard(); self.observeConversationWidth()
            }
        }
    }

    private var peekSuppression: PeekModel.Suppression {
        .init(panelOpen: cardPanelState.isVisible, hidden: visibility.isHidden || suspended,
              quiet: settings.isQuiet(at: Date()), focused: FocusStatus.isFocused)
    }

    private func receivedCard(_ newCard: Card) {
        noteGhostInteraction()
        if messaging.previewEnabled { messaging.previewActivity = .none }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let wasShowing = peek.isVisible
        let suppression = peekSuppression
        if peek.receive(newCard, suppression: suppression, reduceMotion: reduceMotion, typewriter: settings.typewriterEnabled) {
            playPopupSound(appeared: !wasShowing, suppression: suppression)
            status.notePeek(newCard, reduceMotion: reduceMotion, typewriter: peek.types)
            peekExitTask?.cancel()
            positionPeek()
            peekPanel.orderFrontRegardless()
            refreshSurfaceActivity()
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                userInfo: [.announcement: newCard.title ?? String(newCard.body.split(separator: ".").first ?? ""),
                           .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        } else {
            conversation.noteArrival(newCard, visible: cardPanelState.isVisible && cardPanelState.atBottom,
                                     animate: settings.typewriterEnabled && !reduceMotion)
            if !peek.isVisible { status.noteNewCard(newCard) }
        }
    }

    /// Once per pop-up, rate-limited, and never while the peek itself would be suppressed (N2).
    func playPopupSound(appeared: Bool, suppression: PeekModel.Suppression, now: Date = Date()) {
        guard popupSoundGate.shouldPlay(enabled: settings.popupSoundEnabled, appeared: appeared, suppression: suppression, now: now) else { return }
        popupSound.play(settings.popupSound)
    }

    private func expandPeek(_ action: PeekModel.OpenAction) {
        guard let expansion = peek.expand(action) else { return }
        if expansion.reply { conversation.rearmReplyTarget(cardID: expansion.cardID) }
        openConversation(at: expansion.cardID)
    }

    private func hidePeekImmediately() {
        if let id = peek.card?.id { status.stopPeekSpeech(cardID: id) }
        peek.close()
        peekExitTask?.cancel()
        peekPanel.orderOut(nil)
        refreshSurfaceActivity()
    }

    private func observePeekVisibility() {
        withObservationTracking { _ = peek.isVisible } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.peek.isVisible {
                    self.peekExitTask?.cancel()
                    self.positionPeek()
                    self.peekPanel.orderFrontRegardless()
                    self.refreshSurfaceActivity()
                } else {
                    if let id = self.peek.card?.id { self.status.stopPeekSpeech(cardID: id) }
                    self.peekExitTask = Task { @MainActor [weak self] in
                        do { try await Task.sleep(for: .seconds(ZeusPeekTiming.exitDuration)) } catch { return }
                        guard let self, !self.peek.isVisible else { return }
                        self.peekPanel.orderOut(nil)
                        self.refreshSurfaceActivity()
                    }
                }
                self.observePeekVisibility()
            }
        }
    }

    private func observePeekLayoutInputs() {
        withObservationTracking {
            _ = peek.card
            _ = peek.moreCount
            _ = peek.answerError
            _ = peek.answeredOptionID
            _ = settings.fontChoice
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.positionPeek()
                self.observePeekLayoutInputs()
            }
        }
    }

    private func positionPeek() {
        guard let message = peek.card,
              let screen = PanelPlacement.screen(for: avatar.frame, in: screenRects) else { return }
        let layout = PeekLayout.measure(card: message, font: settings.fontChoice, moreCount: peek.moreCount,
                                        error: peek.answerError, answeredOptionID: peek.answeredOptionID,
                                        available: screen.insetBy(dx: 8, dy: 8).size)
        let placement = PeekPlacement.place(art: screenArtRect, anchorX: screenAnchor.x, contentSize: layout.contentSize, screen: screen)
        if peekPanelState.layout != layout { peekPanelState.layout = layout }
        if peekPanelState.tail != placement.tail { peekPanelState.tail = placement.tail }
        peekPanel.setFrame(placement.frame, display: true)
    }

    private var screenArtRect: CGRect { artLayout.rect.screenRect(canvasOrigin: avatar.frame.origin) }

    private func savePosition() {
        defaults.set(screenAnchor.x, forKey: "avatar.anchor.x")
        defaults.set(screenAnchor.y, forKey: "avatar.anchor.y")
    }

    func resetPosition() {
        guard let screen = NSScreen.main?.visibleFrame ?? screenRects.first else { return }
        moveAnchor(to: CGPoint(x: screen.maxX - 160, y: screen.minY + 90))
        savePosition()
    }

    @objc private func screensChanged(_ notification: Notification) {
        resizeFixedX = nil
        moveAvatar(to: avatar.frame.origin)
        savePosition()
    }

    func injectDemo(_ kind: DemoCardKind) {
        cards.add(kind.make())
        // Incoming bubbles never steal focus or reopen a panel the user closed.
    }

    /// Menu recovery must bring its confirmation into view instead of silently arming Settings.
    func performManagedAction(_ action: ZeusManagedPresentation.Action, onConfirmation: (() -> Void)? = nil) {
        managed.perform(action)
        switch managed.confirmation {
        case .newConversation?, .restartForUpdate?: break
        default: return
        }
        if let onConfirmation { onConfirmation() } else { showSettings(tab: .agent) }
    }

    func showSettings(tab: SettingsTab? = nil) {
        login.refresh()
        if let tab { settingsNavigation.tab = tab }
        closeCard()
        if settingsWindow == nil {
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: SettingsWindowSize.minimum),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Zeus Settings"
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: SettingsView(settings: settings, managed: managed, cards: cards, status: status,
                                                                      messaging: messaging, preview: messaging, testMessage: testMessage,
                                                                      injectDemo: { [weak self] in self?.injectDemo($0) },
                                                                      resetPosition: { [weak self] in self?.resetPosition() },
                                                                      navigation: settingsNavigation, login: login, hotKey: hotKey, activity: surfaceActivity, updater: updater, learn: learn))
            host.sizingOptions = []
            window.contentView = host
            SettingsWindowSize.restore(window, from: defaults, screen: NSScreen.main)
            window.center()
            settingsWindow = window
            window.delegate = self
        }
        NSApplication.shared.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
        refreshSurfaceActivity()
    }

    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === settingsWindow else { return }
        SettingsWindowSize.save(window.contentRect(forFrameRect: window.frame).size, to: defaults)
    }

    func copySetupCommands() {
        guard let url = SetupCommands.embeddedBridgeURL else { runtimeError = "The bundled zeus-mcp executable is missing."; return }
        var text = SetupCommands.configuration(for: settings.backend, bridgePath: url.path)
        if settings.backend == .claude { text += "\n\n" + SetupCommands.claudeLaunch }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// The character's right-click menu: the same `ZeusMenuModel` as the menu bar icon (MB1).
    func makeContextMenu() -> NSMenu {
        menuModel.makeNSMenu { [weak self] in self?.perform($0) }
    }

    /// "1 assistant session connected", for Connect your own.
    var agentStatusText: String {
        if messaging.previewEnabled { return "Preview messaging" }
        guard messaging.runtime != nil else { return "Not connected to your assistant" }
        switch messaging.sessions.count {
        case 0: return "No assistant connected"
        case 1: return "1 assistant session connected"
        case let n: return "\(n) assistant sessions connected"
        }
    }

    /// The one Zeus menu (MB1, CONTRACT §10.5), top to bottom: status, Zeus itself, its look, the app, Quit.
    var menuModel: ZeusMenuModel {
        typealias Item = ZeusMenuModel.Item
        var top: [Item] = []
        // What the strip says when a question or unread is waiting; choosing it is the strip's jump.
        let target = StatusStripState.avatarTarget(cards: .init(values: cards.cards, seen: cards.seenIDs), status: self.status.presentation)
        let jumpLine: Item? = target.map { target in
            let strip: ZeusStatusStripModel = switch target {
            case .question: .waiting(questions: StatusStripState.questions(.init(values: cards.cards, seen: cards.seenIDs)).count)
            default: .unread(max(cards.unseenCount, 1))
            }
            return .line([strip.glyph?.rawValue, [strip.sentence, strip.actionTitle].compactMap { $0 }.joined(separator: " · ")]
                .compactMap { $0 }.joined(separator: " "), action: .openStatusTarget)
        }
        if let jumpLine, !managed.prioritizesMenuStatus { top.append(jumpLine) } else { top.append(.line(menuStatus)) }
        if managed.enabled {
            for action in managed.menuActions {
                top.append(.action("managed:\(action)", action.menuTitle, .managed(action), isEnabled: !managed.disabledActions.contains(action)))
            }
        } else {
            top.append(.line(agentStatusText))
            let sessions = messaging.sessions
            var picker: [Item] = [.action("session:auto", AssistantSessionPicker.autoTitle(settings: settings, sessions: sessions),
                                          .selectAssistantSession(nil), isOn: settings.assistantSessionKey == nil)]
            picker += AssistantSessionPicker.choices(settings: settings, sessions: sessions).map {
                .action("session:" + $0.id, $0.title, .selectAssistantSession($0.id), isOn: settings.assistantSessionKey == $0.id)
            }
            top.append(Item(id: "session", title: "Assistant session", kind: .submenu([picker])))
            if let notice = settings.assistantSessionNotice { top.append(.line(notice)) }
        }
        if let jumpLine, managed.prioritizesMenuStatus { top.append(jumpLine) } else if let detail = menuUnreadDetail { top.append(.line(detail)) }
        if let issue = menuIssueDetail { top.append(.line(issue)) }
        if let until = visibility.hiddenUntil, visibility.isHidden {
            top.append(.line("Hidden until \(until.formatted(date: .abbreviated, time: .shortened))"))
        }

        var zeus: [Item] = [
            .action("talk", "Talk to Zeus…", .talk, shortcut: talkShortcut),
            .action("visibility", visibility.isHidden ? "Show Zeus" : "Hide Zeus", .toggleVisibility),
            .action("hideHour", MenuPresentation.hideForHour, .hideForHour),
            .action("hideTomorrow", MenuPresentation.hideUntilTomorrow, .hideUntilTomorrow),
        ]
        if messaging.deliveryIssue != nil { zeus.append(.action("delivery", "Delivery problem…", .deliveryProblem)) }

        func grouped<T>(_ values: [T], bundled: [String], id: (T) -> String, item: (T) -> Item) -> [[Item]] {
            let builtIn = values.filter { bundled.contains(id($0)) }.map(item)
            let own = values.filter { !bundled.contains(id($0)) }.map(item)
            return [builtIn, own].filter { !$0.isEmpty }
        }
        let characters = grouped(settings.availableCharacters, bundled: CharacterLibrary.bundledOrder, id: \.id) {
            .action("character:" + $0.id, $0.name, .character($0.id), isOn: $0.id == settings.currentCharacterID)
        }
        let sizes = AvatarSize.allCases.map { Item.action("size:" + $0.rawValue, $0.rawValue.capitalized, .size($0), isOn: $0 == settings.avatarSize) }
        let themes = grouped(settings.availableThemes, bundled: ZeusThemeLibrary.bundledOrder, id: \.id) {
            .action("theme:" + $0.id, $0.name, .theme($0.id), isOn: $0.id == settings.currentThemeID)
        }
        let look: [Item] = [Item(id: "character", title: "Character", kind: .submenu(characters)),
                            Item(id: "size", title: "Size", kind: .submenu([sizes])),
                            Item(id: "theme", title: "Theme", kind: .submenu(themes))]

        var app: [Item] = [
            .action("settings", "Settings…", .settings, shortcut: .init(key: ",", command: true)),
            .action("updates", updater.menuTitle, .checkForUpdates, isEnabled: updater.canCheckForUpdates,
                    help: updater.unavailableReason ?? "Check for a new version of Zeus"),
        ]
        if let reason = updater.unavailableReason { app.append(.line(reason)) }
        app.append(.action("about", "About Zeus", .about))
        return ZeusMenuModel(sections: [top, zeus, look, app, [.action("quit", "Quit Zeus", .quit, shortcut: .init(key: "q", command: true))]])
    }

    private var talkShortcut: ZeusMenuModel.Shortcut? {
        let hotKey = settings.talkHotKey
        guard hotKey.enabled, hotKey.isValid, let key = hotKey.key.lowercased().first else { return nil }
        return .init(key: key, command: hotKey.command, option: hotKey.option, control: hotKey.control, shift: hotKey.shift)
    }

    /// Runs a menu item's action, from either surface.
    func perform(_ action: ZeusMenuModel.Action) {
        switch action {
        case .openStatusTarget: showAvatarConversation()
        case .managed(let action): performManagedAction(action)
        case .selectAssistantSession(let key): settings.assistantSessionKey = key
        case .talk: showTalkPanel()
        case .toggleVisibility: toggleVisibility()
        case .hideForHour: hide(for: .hour)
        case .hideUntilTomorrow: hide(for: .tomorrow)
        case .deliveryProblem: showDeliveryProblem()
        case .character(let id): settings.currentCharacterID = id
        case .size(let size): settings.avatarSize = size
        case .theme(let id): settings.setTheme(id: id)
        case .settings: showSettings()
        case .checkForUpdates: updater.checkForUpdates()
        case .about: showSettings(tab: .about)
        case .quit: NSApplication.shared.terminate(nil)
        }
    }

    /// Reopening Zeus from Finder, Spotlight, Launchpad or the Dock: show Zeus (clearing a timed hide) and open the
    /// conversation; if Zeus still can't be shown, open Settings, so there is always a way back in (MB1).
    func handleReopen() {
        showAvatar()
        if isVisible { showAvatarConversation() } else { showSettings() }
    }

    /// Turning the menu bar icon off while Zeus is hidden shows Zeus first, so there is always one entry point (MB1).
    func menuBarIconSettingChanged() {
        if !settings.showMenuBarIcon && visibility.isHidden { showAvatar() }
    }

    func observeMenuBarIconSetting() {
        withObservationTracking { _ = settings.showMenuBarIcon } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.menuBarIconSettingChanged()
                self.observeMenuBarIconSetting()
            }
        }
    }

}

extension ShellController: AppControlSurface {
    var controlAvatarFrame: CGRect { avatar.frame }
    var controlScreens: [AppControlScreen] {
        NSScreen.screens.map { AppControlScreen(frame: $0.frame, visibleFrame: $0.visibleFrame, scale: $0.backingScaleFactor, isMain: $0 == NSScreen.main) }
    }
    var controlComposerFocused: Bool { cardPanelState.composerFocused }
    var controlPanelOpen: Bool { cardPanelState.isVisible }
    func controlMoveAvatar(to origin: CGPoint) { moveAvatar(to: origin); savePosition() }
    func controlRefreshVisibility() { syncVisibility(); scheduleDeadline() }
}
