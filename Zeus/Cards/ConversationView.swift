import AppKit
import SwiftUI
import Observation
import ZeusDesign
import ZeusProtocol

private struct ThreadFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, new in new }) }
}

struct ConversationView: View {
    let settings: AppSettings
    let store: CardStore
    @Bindable var model: ConversationModel
    let messaging: any AgentMessaging
    let status: AvatarStatusModel
    let panel: ConversationPanelState
    let activity: SurfaceActivity
    let openSettings: () -> Void
    let copySetup: () -> Void
    let resize: (CGFloat) -> Void
    var ratings: MessageRatingsModel? = nil
    var managed: ManagedAssistantModel? = nil
    var openTerminal: () async throws -> Void = {}
    var newConversation: () -> Void = {}
    var resetWidth: () -> Void = {}
    var workInFolder: (String) -> Void = { _ in }
    @FocusState private var composerFocused: Bool
    @FocusState private var focusedControl: ConversationControlTarget?
    @State private var pageCount = ConversationLayout.pageSize
    @State private var contentHeight: CGFloat = 160
    @State private var composerHeight: CGFloat = 40
    // Transient offsets/measurements are deliberately not observable view state.
    @State private var measurements = ConversationMeasurements()
    @State private var visibility = ConversationVisibility()
    @State private var atBottom = true
    @State private var userScrolling = false
    @State private var pendingLatest = false
    @State private var appeared = false
    @State private var userHasScrolled = false
    @State private var scrollDriver = ConversationScrollDriver()
    @State private var lastQuestionJump: String?
    @State private var confirmingClear = false
    @State private var terminalError: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    /// This root's own colors come from the theme directly: the environment it sets applies to its children.
    private var palette: ZeusPalette { settings.currentTheme.palette(for: colorScheme, contrast: colorSchemeContrast) }

    private var loadedPageCount: Int {
        if panel.document.isOpen, let first = panel.document.threadBookmark?.firstEntryID,
           let index = model.thread.firstIndex(where: { $0.id == first }) { return model.thread.count - index }
        return pageCount
    }
    private var threadWidth: CGFloat { panel.document.isOpen ? (panel.document.threadBookmark?.width ?? panel.width) : panel.width }
    private var entries: [ConversationEntry] { Array(model.thread.suffix(loadedPageCount)) }
    // Replace the old 2-point separator with a 24-point strip and its 1-point rule.
    private var stripExtraHeight: CGFloat { ZeusStatusStrip.height(for: settings.fontChoice, scale: settings.fontScale) - 1 }
    private var threadHeight: CGFloat { ConversationLayout.threadHeight(content: contentHeight, composer: composerHeight, screen: panel.screenHeight, strip: stripExtraHeight) }
    private var documentHeight: CGFloat { DocumentPanelGeometry.contentHeight(composer: composerHeight, strip: stripExtraHeight, screen: panel.screenHeight, expanded: panel.document.expanded, tail: panel.tail == nil ? 0 : ZeusDialogTail.height) }
    private var surfaceHeight: CGFloat { panel.document.isOpen ? documentHeight : threadHeight }
    private var assistant: ConnectedSession? {
        if settings.managedSession?.enabled == true { return nil }
        if let key = settings.assistantSessionKey { return messaging.sessions.first { $0.sessionKey == key } }
        let matching = settings.assistantCandidates(messaging.sessions).filter { settings.preferredAgent == nil || $0.agent == settings.preferredAgent }
        return matching.first { $0.supportsChannel } ?? matching.first
    }
    private var managedController: (any ManagedSessionControlling)? {
        (messaging as? any ManagedSessionControlling) ?? ((messaging as? AgentMessagingHub)?.runtime as? any ManagedSessionControlling)
    }
    private var currentManagedConfiguration: ManagedSessionConfig? {
        ManagedPresentationConfiguration.current(desired: settings.managedSession, launched: settings.managedLaunchedConfig, controller: managedController)
    }
    private var viewport: ConversationViewport {
        get { measurements.viewport }
        nonmutating set { measurements.viewport = newValue }
    }
    private var frames: [String: CGRect] {
        get { measurements.frames }
        nonmutating set { measurements.frames = newValue }
    }
    private var indicator: ConversationActivityPresentation? {
        let runtime = (messaging as? ZeusRuntime) ?? ((messaging as? AgentMessagingHub)?.runtime as? ZeusRuntime)
        let controller = (messaging as? any ManagedSessionControlling) ?? ((messaging as? AgentMessagingHub)?.runtime as? any ManagedSessionControlling)
        return .make(messaging.assistantActivity, panelVisible: panel.isVisible,
                     sessionLabel: messaging.assistantActivity.map { settings.sessionLabels.label($0.sessionKey) },
                     managedStatus: settings.managedSession?.enabled == true ? controller?.managedStatus : nil,
                     managedSessionKey: runtime?.managedController.sessionKey)
    }
    private var newestMessageTop: CGFloat? { frames["latestMessage"]?.minY }
    private var replyTitle: String? {
        model.replyTarget.map { $0.title ?? String($0.body.prefix(40)) + ($0.body.count > 40 ? "…" : "") }
    }
    private var totalHeight: CGFloat { surfaceHeight + composerHeight + 54 + stripExtraHeight + (panel.tail == nil ? 0 : ZeusDialogTail.height) }
    private var stripCards: StatusStripState.Cards {
        .init(values: store.cards, seen: store.seenIDs, outgoing: store.outgoingStates,
              pendingIDs: store.pendingHistoryIDs?() ?? [], canClear: !store.cards.isEmpty || !store.notices.isEmpty)
    }
    private var stripStatus: StatusStripState.Status {
        .init(avatar: status.presentation, deliveryProblem: status.deliveryProblem != nil || messaging.deliveryIssue != nil,
              quietUntil: settings.isQuiet(at: status.now) ? settings.nextQuietBoundary(after: status.now).map { $0.formatted(.dateTime.hour().minute()) } : nil)
    }
    private var stripManaged: StatusStripState.Managed {
        let enabled = settings.managedSession?.enabled == true
        let own = ConversationTerminalTarget.make(session: assistant, configuredPane: settings.tmuxTarget, configuredSocket: settings.tmuxTargetSocketPath)
        return .init(enabled: enabled, isOff: managed?.assistantIsOff(connectedSessionCount: messaging.sessions.count) == true, status: managedController?.managedStatus ?? .off,
                     hasTerminal: enabled ? managedController?.managedTmuxSessionName != nil : own != nil,
                     canStartNew: managed?.canStart == true && managed?.switching != true)
    }

    static func composerAssistantName(_ assistant: ConnectedSession?) -> String? {
        assistant.map { ZeusAgentName.short($0.agent) }
    }

    /// Naming a configured agent before it runs suggests a connection that doesn't exist yet.
    static func composerPlaceholder(managed: ManagedSessionConfig?, status: ManagedSessionStatus?, assistantLabel: String?) -> String {
        if let managed, managed.enabled {
            switch status {
            case .running?, .blocked?, .restarting?: return ZeusAgentName.composerPlaceholder(ZeusAgentName.short(managed.agent))
            default: return ZeusAgentName.composerPlaceholder(nil)
            }
        }
        return ZeusAgentName.composerPlaceholder(assistantLabel)
    }

    // T1: the selected theme reaches every view below through \.zeusTheme (and so \.zeusPalette).
    var body: some View { rootBody.environment(\.zeusTheme, settings.currentTheme) }

    @ViewBuilder private var rootBody: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 8) {
                ZStack(alignment: .top) {
                    thread(proxy: proxy)
                        .opacity(panel.document.isOpen ? 0 : 1)
                        .allowsHitTesting(!panel.document.isOpen)
                        .accessibilityHidden(panel.document.isOpen)
                    if panel.document.isOpen {
                        DocumentViewerView(model: panel.document, conversation: model,
                            back: { backFromDocument(proxy) }, context: { returnFromDocument(proxy) })
                            .frame(height: documentHeight)
                            .overlay(alignment: .top) { documentPills(edge: .top, proxy: proxy) }
                            .overlay(alignment: .bottom) { documentPills(edge: .bottom, proxy: proxy) }
                            .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
                    }
                }.frame(height: surfaceHeight, alignment: .top).clipped()
                    .animation(.easeOut(duration: reduceMotion ? 0.12 : 0.18), value: panel.document.isOpen)
                ZeusStatusStrip(StatusStripState.make(cards: stripCards, status: stripStatus, managed: stripManaged, activity: indicator),
                    onJump: StatusStripState.jump(cards: stripCards, status: stripStatus, managed: stripManaged, activity: indicator) == nil ? nil : { jumpStatus(proxy) },
                    onSkip: canSkipFromStrip ? { skipFromStrip() } : nil,
                    onButton: stripButton)
                VStack(spacing: 8) {
                    attachmentDraft
                    ZeusComposer(text: $model.draft, placeholder: panel.document.current.map { "Ask about \($0.attachment.label)…" } ?? Self.composerPlaceholder(managed: currentManagedConfiguration,
                        status: managedController?.managedStatus,
                        assistantLabel: Self.composerAssistantName(assistant)),
                                 replyingTo: replyTitle, isSending: model.isSending, hasAttachments: !model.draftAttachments.isEmpty, focus: $composerFocused,
                                 onClearReply: { model.clearReplyTarget(); composerFocused = true },
                                 onSend: {
                                     Task {
                                         await Self.sendFromComposer(model)
                                         if model.draft.isEmpty { panel.document.autoAttachedPage = nil }
                                         focusComposer()
                                         // An accepted send returns from history or a thread control to the new bubble.
                                         if model.draft.isEmpty && !panel.document.isOpen { latest(proxy) }
                                     }
                                 })
                    if let error = model.attachmentError { Text(error).zeusFont(.caption).foregroundStyle(palette.destructive) }
                    if let hub = messaging as? AgentMessagingHub { AgentLinkStatusView(hub: hub) }
                    if let terminalError { Text(terminalError).zeusFont(.caption).foregroundStyle(palette.destructive) }
                    if case .rejected(let reason) = model.result { Text(reason).zeusFont(.caption).foregroundStyle(palette.destructive) }
                    else if let error = store.persistenceError { Text(error).zeusFont(.caption).foregroundStyle(palette.destructive).textSelection(.enabled) }
                }
                // Measure the composer's ideal height before allocating the remaining height
                // to the scrolling thread; a previous panel size must not clamp new lines.
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
            }
            .zeusDialog(tail: panel.tail)
            .frame(width: panel.width)
            .padding(.bottom, 4)
            .environment(\.zeusAnimationsActive, activity.conversation)
            .environment(\.openDocument, { attachment, entryID in
                let id = entryID.flatMap { $0.hasPrefix("card:") ? String($0.dropFirst(5)) : nil }
                let card = id.flatMap { store.card(id: $0) }
                let offset = scrollDriver.viewport?.offset ?? viewport.offset
                let bookmark = entryID.flatMap { entry in frames[entry].map {
                    DocumentViewerModel.ThreadBookmark(entryID: entry, relativeTop: $0.minY - offset,
                        firstEntryID: entries.first?.id, width: panel.width, viewportWidth: scrollDriver.scrollView?.bounds.width)
                } }
                guard panel.document.open(attachment, siblings: card?.attachments ?? [attachment], sourceCardID: id,
                                          context: card.map { $0.title ?? ZeusMarkdown.spokenText(markdown: $0.body).components(separatedBy: ".").first ?? "" }) else { return false }
                scrollDriver.stopRestoring()
                panel.document.threadBookmark = bookmark
                panel.document.threadOffset = offset; panel.document.threadPageCount = pageCount; panel.document.fromPeek = false
                setPinned(false); scrollDriver.stopFollowing(); composerFocused = false; focusedControl = nil
                return true
            })
            .environment(\.zeusFontChoice, settings.fontChoice)
            .environment(\.zeusFontScale, settings.fontScale)
            .environment(\.openURL, OpenURLAction { url in
                if url == WelcomeCard.agentSettingsURL { openSettings(); return .handled }
                guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return .discarded }
                return NSWorkspace.shared.open(url) ? .handled : .discarded
            })
            .modifier(PixelAppearance(progress: appeared ? 1 : 0))
            .background { shortcuts(proxy: proxy) }
            .background { ConversationResizeColor(color: NSColor(palette.focusRing)).frame(width: 0, height: 0).accessibilityHidden(true) }
            .contextMenu {
                Button("Reset width", action: resetWidth).accessibilityLabel("Reset conversation width")
                ClearConversationButton(cards: store)
            }
            .alert("Clear the conversation?", isPresented: $confirmingClear) {
                Button("Clear", role: .destructive) { _ = store.clearConversation() }
                Button("Cancel", role: .cancel) {}
            } message: { Text(ConversationHistoryCopy.confirmation) }
            .onChange(of: totalHeight, initial: true) { resize(totalHeight) }
            .onChange(of: panel.document.isOpen) {
                if panel.document.isOpen { setPinned(false); scrollDriver.stopFollowing(); scrollDriver.stopRestoring() }
                else if !scrollDriver.isRestoring {
                    Task { @MainActor in await Task.yield(); panel.document.removeEmptyAutomaticAttachments(in: model) }
                }
            }
            .onChange(of: panel.document.expanded) { resize(totalHeight) }
            .onChange(of: panel.document.backRequest) { backFromDocument(proxy) }
            .onChange(of: panel.document.composerRequest) { focusComposer() }
            .onChange(of: model.draft) { panel.document.typed(in: model) }
            .onChange(of: store.conversationClearRevision) { scrollDriver.stopRestoring(); panel.document.close() }
            .onChange(of: composerHeight) { followLatest() }
            .onChange(of: composerFocused) { panel.composerFocused = composerFocused }
            .onChange(of: panel.keyboardScrollRequest) {
                guard let command = panel.keyboardScroll else { return }
                scrollDriver.stopRestoring()
                userHasScrolled = true
                switch command {
                case .latest: latest(proxy)
                case .oldest:
                    setPinned(false)
                    pageCount = model.thread.count
                    Task { @MainActor in await Task.yield(); if let first = model.thread.first { proxy.scrollTo(first.id, anchor: .top) } }
                case .line, .page:
                    scrollDriver.perform(command)
                    if let current = scrollDriver.viewport {
                        viewport = current
                        setPinned(ConversationAutoScroll.isPinned(viewport: current, newestMessageTop: newestMessageTop))
                    }
                }
            }
            .onChange(of: focusedControl) { _, target in
                #if DEBUG || ZEUS_PERFORMANCE_PROBE
                panel.focusedControlForDiagnostics = target
                #endif
                guard let target else { return }
                // A person operating thread controls owns the viewport until they jump to latest.
                setPinned(false)
                // A pointer already reached its target. Centering it now moves the button
                // out from under a held press. Keyboard focus still reveals its target.
                guard !panel.focusCameFromPointer, !panel.document.isOpen else { return }
                scrollDriver.stopRestoring()
                Task { @MainActor in
                    await Task.yield()
                    guard panel.isVisible, focusedControl == target, !panel.focusCameFromPointer else { return }
                    proxy.scrollTo(target, anchor: .center)
                }
            }
            .onChange(of: panel.focusRequest) { focusComposer() }
            .onChange(of: panel.scrollRequest) { if !panel.document.isOpen { openTarget(proxy) } }
            .onAppear {
                guard panel.isVisible else { return }
                if panel.document.isOpen {
                    pageCount = max(loadedPageCount, panel.document.threadPageCount); setPinned(false)
                    Task { @MainActor in
                        await Task.yield()
                        if let bookmark = panel.document.threadBookmark { proxy.scrollTo(bookmark.entryID, anchor: .top) }
                        else if let offset = panel.document.threadOffset { scrollDriver.scroll(to: offset) }
                    }
                }
                if ratings?.drafts.isEmpty != false { focusComposer() }; if !panel.document.isOpen { openTarget(proxy) }
                withAnimation(.easeOut(duration: 0.12)) { appeared = true }
            }
            .onChange(of: panel.isVisible) {
                if panel.isVisible {
                    visibility.jumpsReady = false
                    lastQuestionJump = nil
                    model.openPanel(viewportManaged: true)
                    if !panel.document.isOpen { pageCount = ConversationLayout.pageSize }
                    userHasScrolled = false
                    if ratings?.drafts.isEmpty != false { focusComposer() }; if !panel.document.isOpen { openTarget(proxy) }
                    withAnimation(.easeOut(duration: 0.12)) { appeared = true }
                } else {
                    visibility.jumpsReady = false
                    model.closePanel(); composerFocused = false
                    withAnimation(.easeOut(duration: 0.08)) { appeared = false }
                }
            }
            .onDisappear { scrollDriver.stopFollowing(); scrollDriver.stopRestoring() }
            .onChange(of: messaging.assistantActivity) { _, current in
                guard panel.isVisible else { return }
                if (!atBottom || userScrolling), current != nil { pendingLatest = true }
                if current != nil { followLatest() }
            }
            .onChange(of: model.thread.last?.body) { _, _ in
                if !atBottom && model.thread.last?.isRatingHeld != true { pendingLatest = true }
            }
            .onChange(of: model.thread.map(\.id)) { old, _ in
                guard panel.isVisible else { return }
                let arrivals = model.thread.filter { !old.contains($0.id) }
                let added = arrivals.filter { !$0.isRatingHeld }
                guard arrivals.isEmpty || !added.isEmpty else { return }
                if atBottom && !userScrolling && !panel.document.isOpen { frames.removeValue(forKey: "latestMessage"); latest(proxy) } else { pendingLatest = true }
                if let entry = added.last(where: { !$0.isUser }) {
                    NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                        userInfo: [.announcement: announcement(entry), .priority: NSAccessibilityPriorityLevel.medium.rawValue])
                }

            }
            .background {
                ConversationSeenTracker(visibility: visibility, entries: entries, store: store, panel: panel, activity: activity)
            }
        }
    }

    private func backFromDocument(_ proxy: ScrollViewProxy) {
        let sourceID = panel.document.current?.sourceCardID
        let count = loadedPageCount
        guard panel.document.back() else { return }
        pageCount = count
        resize(totalHeight) // Restore chat width before the hidden lazy thread is presented.
        if panel.document.fromPeek, panel.document.threadBookmark == nil, panel.document.threadOffset == nil {
            panel.scrollTargetCardID = sourceID; panel.focusScrollTarget = false
            openTarget(proxy)
            Task { @MainActor in
                await Task.yield(); await Task.yield()
                guard panel.isVisible, !panel.document.isOpen else { return }
                focusComposer()
                panel.document.removeEmptyAutomaticAttachments(in: model)
            }
            return
        }
        let target = panel.document.fromPeek ? nil : panel.document.returnTarget
        panel.focusCameFromPointer = true
        scrollDriver.restore(to: scrollDriver.viewport?.offset ?? panel.document.threadOffset ?? 0) {
            Task { @MainActor in
                await Task.yield()
                guard panel.isVisible, !panel.document.isOpen, scrollDriver.isRestoring else { return }
                if let target { composerFocused = false; focusedControl = target } else { focusComposer() }
                panel.document.removeEmptyAutomaticAttachments(in: model)
            }
        }
        if panel.document.threadBookmark != nil {
            Task { @MainActor in
                await Task.yield()
                guard !panel.document.isOpen, scrollDriver.isRestoring else { return }
                restoreDocumentAnchor()
            }
        } else if let offset = panel.document.threadOffset { scrollDriver.restore(to: offset) }
    }
    private func restoreDocumentAnchor() {
        guard scrollDriver.isRestoring, !panel.document.isOpen,
              let bookmark = panel.document.threadBookmark,
              let frame = frames[bookmark.entryID] else { return }
        scrollDriver.restore(to: frame.minY - bookmark.relativeTop)
    }
    private func returnFromDocument(_ proxy: ScrollViewProxy) {
        let id = panel.document.current?.sourceCardID
        let target = panel.document.fromPeek ? nil : panel.document.returnTarget
        panel.document.close()
        panel.scrollTargetCardID = id; panel.focusScrollTarget = false
        openTarget(proxy)
        Task { @MainActor in
            await Task.yield(); await Task.yield()
            panel.focusCameFromPointer = true
            if let target { composerFocused = false; focusedControl = target } else { focusComposer() }
        }
    }
    private func documentPills(edge: ZeusJumpPillCluster.Edge, proxy: ScrollViewProxy) -> some View {
        let unseen = model.thread.filter { !$0.isUser && !$0.isNotice && !$0.isRatingHeld && !store.seenIDs.contains($0.sourceCardID) }
        let questions = StatusStripState.questions(stripCards).map(\.id)
        let next = ConversationJumpState.nextQuestion(questions: questions, visible: visibility.navigationIDs, after: lastQuestionJump)
        let nextIndex = next.flatMap { id in model.thread.firstIndex { $0.sourceCardID == id } } ?? 0
        let currentIndex = panel.document.current?.sourceCardID.flatMap { id in model.thread.firstIndex { $0.sourceCardID == id } } ?? 0
        let up = nextIndex < currentIndex
        var items: [ZeusJumpPillCluster.Item] = []
        if edge == .bottom && !unseen.isEmpty {
            items.append(.init(.latest(newCount: unseen.count), action: {
                panel.document.close(); panel.scrollTargetCardID = unseen.first?.sourceCardID; panel.focusScrollTarget = false; openTarget(proxy)
            }))
        }
        if next != nil && ((edge == .top) == up) {
            items.append(.init(.question(count: questions.count, direction: up ? .up : .down), action: { panel.document.close(); jumpQuestion(proxy) }))
        }
        return ZeusJumpPillCluster(edge: edge, items: items).padding(.vertical, ZeusTheme.Spacing.xs)
    }

    @ViewBuilder private var attachmentDraft: some View {
        ContextDraftAttachments(model: model, managed: managed?.enabled == true, workInFolder: workInFolder)
    }

    /// The composer delegates draft ownership to the model, including failed sends.
    @MainActor static func sendFromComposer(_ model: ConversationModel) async {
        await model.send()
    }

    private func announcement(_ entry: ConversationEntry) -> String {
        if case .agentCard(let card) = entry.content, let title = card.title { return title }
        return String(entry.body.split(separator: ".").first ?? "")
    }
    private func focusComposer() {
        focusedControl = nil
        composerFocused = false
        Task { @MainActor in await Task.yield(); composerFocused = panel.isVisible }
    }
    private func openTarget(_ proxy: ScrollViewProxy) {
        scrollDriver.stopRestoring()
        panel.document.close()
        guard let id = panel.scrollTargetCardID,
              let index = model.thread.firstIndex(where: { $0.sourceCardID == id }) else { latest(proxy); return }
        if id == model.thread.last?.sourceCardID && !panel.focusScrollTarget { latest(proxy); return }
        setPinned(false)
        pageCount = max(ConversationLayout.pageSize, model.thread.count - index)
        Task { @MainActor in
            await Task.yield()
            guard panel.isVisible, panel.scrollTargetCardID == id else { return }
            proxy.scrollTo("card:\(id)", anchor: .top)
            await Task.yield()
            guard panel.isVisible, panel.scrollTargetCardID == id else { return }
            visibility.jumpsReady = true
            if panel.focusScrollTarget, let card = store.card(id: id), card.status == .open {
                if !card.id.hasPrefix(ZeusRuntime.managedCardPrefix) { model.rearmReplyTarget(cardID: id); lastQuestionJump = id }
                if let target = StatusStripState.firstControl(card) {
                    composerFocused = false
                    await Task.yield()
                    guard panel.isVisible, panel.scrollTargetCardID == id, store.card(id: id)?.status == .open else { return }
                    proxy.scrollTo(target, anchor: .center)
                    await Task.yield()
                    focusedControl = target
                } else { focusComposer() }
            }
        }
    }
    private var canSkipFromStrip: Bool {
        StatusStripState.make(cards: stripCards, status: stripStatus, managed: stripManaged, activity: indicator).skipTitle != nil
    }
    private func skipFromStrip() {
        panel.document.close()
        guard canSkipFromStrip, let card = StatusStripState.questions(stripCards).first else { return }
        setPinned(false)
        if store.skip(id: card.id), !store.hasOpenQuestion || focusedControl?.entryID == "card:\(card.id)" { focusComposer() }
    }
    private func jumpStatus(_ proxy: ScrollViewProxy) {
        guard let target = StatusStripState.jump(cards: stripCards, status: stripStatus, managed: stripManaged, activity: indicator) else { return }
        if case .question = target { jumpQuestion(proxy); return }
        switch target {
        case .latest: latest(proxy)
        case .terminal: performOpenTerminal()
        default:
            panel.scrollTargetCardID = target.cardID
            switch target { case .question, .prompt: panel.focusScrollTarget = true; default: panel.focusScrollTarget = false }
            openTarget(proxy)
        }
    }
    /// Both the strip and floating question pill advance this single cursor.
    private func jumpQuestion(_ proxy: ScrollViewProxy) {
        guard let id = ConversationJumpState.nextQuestion(
            questions: StatusStripState.questions(stripCards).map(\.id),
            visible: visibility.navigationIDs, after: lastQuestionJump) else { return }
        lastQuestionJump = id
        panel.scrollTargetCardID = id
        panel.focusScrollTarget = true
        openTarget(proxy)
    }
    private func stripButton(_ button: ZeusStatusStripModel.Button) {
        switch button {
        case .terminal: performOpenTerminal()
        case .newConversation: newConversation()
        case .clear: confirmingClear = true
        case .settings: openSettings()
        }
    }
    private func performOpenTerminal() {
        terminalError = nil
        Task {
            do { try await openTerminal() }
            catch { terminalError = "Couldn't open Terminal. \(error.localizedDescription)" }
        }
    }
    private func updateSeenVisibility() {
        guard !panel.document.isOpen else { return }
        let ids = ConversationViewportVisibility.visibleIDs(frames: frames, viewport: viewport)
        if visibility.navigationIDs != ids { visibility.navigationIDs = ids }
        let away = ConversationJumpState.awayFromLatest(viewport: viewport, newestMessageTop: newestMessageTop)
        if visibility.awayFromLatest != away { visibility.awayFromLatest = away }
        let seenIDs = ids.filter { $0.hasPrefix("card:") }
        if visibility.seenIDs != seenIDs { visibility.seenIDs = seenIDs }
    }

    private func recordScrollDiagnostics() {
        #if DEBUG || ZEUS_PERFORMANCE_PROBE
        panel.activityRowVisibleForDiagnostics = indicator != nil && visibility.ids.contains("assistantActivity")
        panel.viewportForDiagnostics = viewport
        panel.newestMessageTopForDiagnostics = newestMessageTop
        panel.newestMessageFrameForDiagnostics = frames["latestMessage"]
        #endif
    }

    private func setPinned(_ pinned: Bool) {
        if atBottom != pinned { atBottom = pinned }
        if panel.atBottom != pinned { panel.atBottom = pinned }
        if pinned { pendingLatest = false } else { scrollDriver.stopFollowing() }
    }

    private func followLatest() {
        guard panel.isVisible, atBottom, !userScrolling, !panel.document.isOpen else { return }
        guard model.thread.isEmpty || newestMessageTop != nil else { return }
        scrollDriver.followLatest(newestMessageTop: newestMessageTop)
    }

    private func latest(_ proxy: ScrollViewProxy) {
        scrollDriver.stopRestoring()
        panel.document.close()
        setPinned(true)
        // Realize the newest lazy row before applying its measured cap. Top alignment is safe
        // even before measurements: short rows clamp to the end, tall rows start at their top.
        Task { @MainActor in
            await Task.yield()
            guard panel.isVisible, atBottom, !userScrolling, !panel.document.isOpen else { return }
            if let last = model.thread.last { proxy.scrollTo(last.id, anchor: .top) }
            else { proxy.scrollTo("bottom", anchor: .bottom) }
            await Task.yield()
            followLatest()
            await Task.yield()
            if panel.isVisible { visibility.jumpsReady = true }
        }
    }

    private func thread(proxy: ScrollViewProxy) -> some View {
        let allEntries = model.thread
        let loadedEntries = Array(allEntries.suffix(loadedPageCount))
        let sources = Dictionary(uniqueKeysWithValues: store.cards.map { ($0.id, $0) })
        let labeledEntries = ConversationLayout.sessionLabelEntries(loadedEntries, cards: store.cards)
        let rows = loadedEntries.indices.map { index in
            ConversationThreadRow(entry: loadedEntries[index], previous: index == 0 ? nil : loadedEntries[index - 1], first: index == 0)
        }
        let shortcutID = model.shortcutTarget?.id
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if model.thread.count > loadedPageCount {
                    Button("Load Earlier Messages") {
                        setPinned(false)
                        let first = entries.first?.id
                        pageCount += ConversationLayout.pageSize
                        Task { @MainActor in await Task.yield(); if let first { proxy.scrollTo(first, anchor: .top) } }
                    }.accessibilityLabel("Load Earlier Messages").buttonStyle(ZeusButtonStyle(.secondary, size: .small)).focusable()
                    .modifier(ConversationControlFocus(focus: $focusedControl,
                              target: .init(entryID: "history", controlID: "loadEarlier")))
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("thread")) } action: { frame in
                        if userHasScrolled && panel.isVisible && frame.minY >= 0 && frame.maxY <= threadHeight && contentHeight > threadHeight {
                            let first = entries.first?.id
                            pageCount += ConversationLayout.pageSize
                            Task { @MainActor in await Task.yield(); if let first { proxy.scrollTo(first, anchor: .top) } }
                        }
                    }
                }
                if entries.isEmpty && indicator == nil {
                    if settings.managedSession?.enabled == true {
                        ManagedEmptyThread(onOpenSettings: openSettings).frame(height: 160)
                    } else { ZeusEmptyThread(assistantName: assistant?.clientName, onOpenSettings: openSettings).frame(height: 160) }
                }
                ForEach(rows) { row in
                    rowContent(row, sources: sources, labeledEntries: labeledEntries, latestID: loadedEntries.last?.id, shortcutID: shortcutID)
                        .id(row.id)
                }
                if let indicator {
                    ConversationVisibleActivity(presentation: indicator, visibility: visibility, activity: activity)
                        .padding(.top, entries.isEmpty ? 0 : 10)
                        .id("assistantActivity")
                        .background(GeometryReader { geometry in
                            Color.clear.preference(key: ThreadFrames.self, value: ["assistantActivity": geometry.frame(in: .named("threadContent"))])
                        })
                }
                Color.clear.frame(height: 1).id("bottom")
                    .background(GeometryReader { geometry in Color.clear.preference(key: ThreadFrames.self, value: ["bottom": geometry.frame(in: .named("threadContent"))]) })
            }
            .scrollTargetLayout()
            .coordinateSpace(name: "threadContent")
            .background(ConversationScrollProbe(driver: scrollDriver))
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                // A capped thread doesn't resize when offscreen rows refine their estimates.
                let nextHeight = ConversationLayout.threadHeight(content: $0, composer: composerHeight, screen: panel.screenHeight, strip: stripExtraHeight)
                if abs(nextHeight - threadHeight) > 0.5 { contentHeight = $0 }
            }
        }
        .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.01) { ids in
            let next = Set(ids)
            if visibility.ids != next { visibility.ids = next }
            recordScrollDiagnostics()
        }
        .defaultScrollAnchor(.top, for: .sizeChanges)
        .onScrollPhaseChange { _, phase in
            #if DEBUG || ZEUS_PERFORMANCE_PROBE
            if ProcessInfo.processInfo.environment["ZEUS_PERF_SCROLL"] == "1" { panel.scrollPhasesForDiagnostics.append(String(describing: phase)) }
            #endif
            let wasScrolling = userScrolling
            let scrolling = phase == .interacting || phase == .decelerating
            if userScrolling != scrolling { userScrolling = scrolling }
            if userScrolling { userHasScrolled = true; scrollDriver.stopFollowing(); scrollDriver.stopRestoring() }
            if userScrolling || wasScrolling {
                setPinned(ConversationAutoScroll.isPinned(viewport: viewport, newestMessageTop: newestMessageTop))
                if !userScrolling { followLatest() }
            }
        }
        .onScrollGeometryChange(for: ConversationViewport.self) { geometry in
            .init(offset: geometry.contentOffset.y + geometry.contentInsets.top,
                  contentHeight: geometry.contentSize.height, height: geometry.containerSize.height)
        } action: { previous, current in
            viewport = current
            updateSeenVisibility()
            recordScrollDiagnostics()
            if userScrolling { setPinned(ConversationAutoScroll.isPinned(viewport: current, newestMessageTop: newestMessageTop)) }
            else if current.contentHeight > previous.contentHeight || previous.height != current.height { followLatest() }
        }
        .coordinateSpace(name: "thread")
        .frame(width: panel.document.isOpen ? panel.document.threadBookmark?.viewportWidth : nil, height: threadHeight)
        .onChange(of: atBottom) { panel.atBottom = atBottom }
        .onPreferenceChange(ThreadFrames.self) { value in
            let previousNewest = frames["latestMessage"]
            let newestChanged = previousNewest != value["latestMessage"]
            let previousBottom = frames["bottom"]?.maxY ?? 0
            let bottomGrew = (value["bottom"]?.maxY ?? 0) > previousBottom
            // Preserve the newest measured cap while its lazy row is offscreen.
            // A subsequent measured frame replaces it; the next arrival clears it first.
            var next = value
            if next["latestMessage"] == nil { next["latestMessage"] = previousNewest }
            frames = next
            restoreDocumentAnchor()
            updateSeenVisibility()
            recordScrollDiagnostics()
            if userScrolling { setPinned(ConversationAutoScroll.isPinned(viewport: viewport, newestMessageTop: newestMessageTop)) }
            else if (newestChanged && value["latestMessage"] != nil) || bottomGrew { followLatest() }
            if !atBottom, let previousNewest, let newest = value["latestMessage"], newest.height > previousNewest.height + 1 { pendingLatest = true }
        }
        .overlay(alignment: .top) { jumpPills(edge: .top, proxy: proxy) }
        .overlay(alignment: .bottom) { jumpPills(edge: .bottom, proxy: proxy) }
        .clipped()
        .accessibilityLabel("Conversation")
    }
    private func jumpPills(edge: ZeusJumpPillCluster.Edge, proxy: ScrollViewProxy) -> some View {
        ConversationJumpOverlay(edge: edge, visibility: visibility, entries: model.thread, store: store,
            questions: StatusStripState.questions(stripCards).map(\.id), lastQuestion: lastQuestionJump,
            atBottom: atBottom, pending: pendingLatest, panel: panel,
            unread: { id in
                panel.scrollTargetCardID = id; panel.focusScrollTarget = false; openTarget(proxy)
            }, latest: { latest(proxy) }, question: { jumpQuestion(proxy) })
            .environment(\.zeusAnimationsActive, activity.conversation && !atBottom)
    }
    private func rowContent(_ row: ConversationThreadRow, sources: [String: Card], labeledEntries: Set<String>, latestID: String?, shortcutID: String?) -> some View {
        let entry = row.entry
        let previous = row.previous
        let grouped = ConversationLayout.grouped(entry, after: previous, sources: sources)
        return VStack(alignment: .leading, spacing: 8) {
            if ConversationLayout.needsDivider(entry, after: previous) { ZeusThreadDivider(ConversationLayout.divider(entry.timestamp)) }
            if labeledEntries.contains(entry.id), let key = sources[entry.sourceCardID]?.sessionKey {
                ZeusSessionLabel(settings.sessionLabels.label(key), colorIndex: ZeusSessionLabel.colorIndex(for: key))
            }
            if let notice = entry.threadNotice {
                ConversationNoticeLine(notice: notice, maxWidth: ConversationWidth.bubble(panelWidth: threadWidth, user: false),
                                       hasAction: store.hasNoticeAction(id: notice.id), perform: { store.performNoticeAction(id: notice.id) },
                                       hasSecondaryAction: store.hasSecondaryNoticeAction(id: notice.id),
                                       performSecondary: { store.performSecondaryNoticeAction(id: notice.id) })
                    .background(GeometryReader { geometry in
                        let frame = geometry.frame(in: .named("threadContent"))
                        Color.clear.preference(key: ThreadFrames.self,
                            value: entry.id == latestID ? [entry.id: frame, "latestMessage": frame] : [entry.id: frame])
                    })
            } else if case .agentCard(let card) = entry.content, let ratings, ratings.isCollapsed(card) {
                MutedMessageLine(card: card, model: ratings)
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: ThreadFrames.self, value: entry.id == latestID ? ["latestMessage": geometry.frame(in: .named("threadContent"))] : [:])
                    })
            } else {
            if case .agentCard(let card) = entry.content, let ratings, ratings.isHeld(card) { MutedMessageLine(card: card, model: ratings) }
            ConversationVisibleBubble(bubble: ConversationBubble(entry: entry, answerCaption: ConversationLayout.answerCaption(entry, after: previous, sources: sources), showTime: !grouped, shortcuts: entry.sourceCardID == shortcutID,
                               model: model, settings: settings, ratings: ratings, isVisible: panel.isVisible, maxWidth: ConversationWidth.bubble(panelWidth: threadWidth, user: entry.isUser),
                               openSettings: openSettings, copySetup: copySetup, sessions: messaging.sessions, focus: $focusedControl,
                               onReply: { id in model.rearmReplyTarget(cardID: id); panel.focusRequest += 1 }), visibility: visibility)
                .background(GeometryReader { geometry in
                    let frame = geometry.frame(in: .named("threadContent"))
                    Color.clear.preference(key: ThreadFrames.self,
                        value: entry.id == latestID ? [entry.id: frame, "latestMessage": frame] : [entry.id: frame])
                })
            }
        }
        .padding(.top, row.first ? 0 : grouped ? 4 : 10)
    }
    private var sessionLabelEntries: Set<String> { ConversationLayout.sessionLabelEntries(entries, cards: store.cards) }
    private func allEntriesCount(from cardID: String) -> Int {
        guard let index = model.thread.firstIndex(where: { $0.sourceCardID == cardID }) else { return ConversationLayout.pageSize }
        return model.thread.count - index
    }
    private func shortcuts(proxy: ScrollViewProxy) -> some View {
        VStack {
            ForEach(1...9, id: \.self) { number in
                Button("") { _ = model.pickNumberedOption(number) }.keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command).focusable(false)
            }
            Button("") { latest(proxy) }.keyboardShortcut(.downArrow, modifiers: .command).focusable(false)
            Button("") {
                guard let ratings else { return }
                let focusedID = focusedControl?.entryID.replacingOccurrences(of: "card:", with: "")
                let target = focusedID.flatMap { store.card(id: $0) }.flatMap { ratings.canRate($0) ? $0 : nil }
                    ?? ratings.keyboardCardID.flatMap { store.card(id: $0) }
                    ?? ratings.focusedRatingCardID.flatMap { ratings.drafts[$0] != nil ? store.card(id: $0) : nil }
                    ?? store.cards.last(where: { ratings.canRate($0) })
                guard let target else { return }
                composerFocused = false; ratings.toggle(target)
                if ratings.drafts[target.id] != nil {
                    pageCount = max(pageCount, allEntriesCount(from: target.id))
                    Task { @MainActor in await Task.yield(); proxy.scrollTo("card:" + target.id, anchor: .center) }
                }
            }.keyboardShortcut("r", modifiers: .command).focusable(false)
            Button("", action: openSettings).keyboardShortcut(",", modifiers: .command).focusable(false)
            ConversationStripKeys(jump: { jumpStatus(proxy) }, skip: canSkipFromStrip ? { skipFromStrip() } : nil)
        }.opacity(0).allowsHitTesting(false).accessibilityHidden(true)
    }
}

private struct ConversationBubble: View, Equatable {
    let entry: ConversationEntry
    let answerCaption: String?
    let showTime: Bool
    let shortcuts: Bool
    let model: ConversationModel
    let settings: AppSettings
    var ratings: MessageRatingsModel? = nil
    var isVisible: Bool
    let maxWidth: CGFloat
    let openSettings: () -> Void
    let copySetup: () -> Void
    let sessions: [ConnectedSession]
    let focus: FocusState<ConversationControlTarget?>.Binding
    let onReply: (String) -> Void
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.entry == rhs.entry && lhs.answerCaption == rhs.answerCaption && lhs.showTime == rhs.showTime
            && lhs.shortcuts == rhs.shortcuts && lhs.isVisible == rhs.isVisible
            && lhs.maxWidth == rhs.maxWidth
            && lhs.model === rhs.model && lhs.ratings === rhs.ratings && lhs.settings === rhs.settings && lhs.sessions == rhs.sessions
    }
    @State private var ratingHovered = false
    @Environment(\.zeusPalette) private var palette

    var body: some View {
        VStack(alignment: entry.isUser ? .trailing : .leading, spacing: 4) {
            if let answerCaption {
                HStack(spacing: 4) { ZeusGlyph(.reply); Text(answerCaption) }
                    .zeusFont(.caption).foregroundStyle(palette.secondaryText)
            }
            ZeusBubble(entry.isUser ? .user : .agent, muted: entry.isMuted || card.map { ratings?.isHeld($0) == true } == true, highPriority: card?.priority == .high && card.map { ratings?.isHeld($0) == true } != true, maxWidth: maxWidth) {
                if let card {
                    if let ratings, ratings.canRate(card), (!ratings.isHeld(card) || ratings.isBudgetHeld(card)) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            if let title = card.title { Text(title).zeusFont(.button).foregroundStyle(palette.title) }
                            Spacer(minLength: 0)
                            if showTime { Text(entry.timestamp.formatted(.dateTime.hour().minute())).zeusFont(.caption).foregroundStyle(palette.secondaryText) }
                            MessageRatingButton(card: card, model: ratings, hovered: ratingHovered,
                                showAtRest: !ratings.hasOpenedRow && ratings.newestUnpromptedID == card.id)
                        }
                    } else if card.title != nil || card.kind == .progress {
                        ZeusBubbleHeader(title: card.title ?? String(card.body.split(separator: "\n").first ?? ""),
                                         trailing: showTime ? entry.timestamp.formatted(.dateTime.hour().minute()) : nil)
                    }
                    if card.kind != .progress { bodyText }
                    ForEach(card.attachments, id: \.id) { attachment in
                        attachmentRow(attachment)
                    }
                    if card.kind == .progress || card.progress != nil { ZeusProgressRow(value: card.progress.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }) }
                    if card.status == .open && !entry.isMuted {
                        ZeusFlowLayout(spacing: ZeusTheme.Spacing.s) {
                            ForEach(Array(card.options.enumerated()), id: \.element.id) { index, option in
                                Button { _ = model.pickOption(cardID: card.id, optionID: option.id) } label: {
                                    HStack(spacing: 4) {
                                        Text(option.label)
                                        if shortcuts, let key = ZeusOptionButtons.shortcutLabel(index: index) { Text(key).zeusFont(.badge).opacity(ZeusOptionButtons.shortcutOpacity) }
                                    }
                                }.accessibilityLabel(option.label).buttonStyle(ZeusButtonStyle(option.style))
                                 .focusable()
                                 .modifier(ConversationControlFocus(focus: focus, target: .init(entryID: entry.id, controlID: "option:\(option.id)")))
                            }
                            if card.kind == .question, card.input != nil {
                                Button("Reply…") { onReply(card.id) }
                                    .accessibilityLabel("Reply to \(card.title ?? "this question")")
                                    .buttonStyle(ZeusButtonStyle(.secondary, size: .small)).focusable()
                                    .modifier(ConversationControlFocus(focus: focus, target: .init(entryID: entry.id, controlID: "reply")))
                            }
                        }
                    } else {
                        ZeusOptionButtons(card.options, state: optionState(card)) { _ in }
                    }
                    if let ratings, ratings.canRate(card) { MessageRatingInline(card: card, model: ratings) }
                    if card.id == WelcomeCard.id {
                        Button("Settings → Assistant", action: openSettings).accessibilityLabel("Settings, Assistant").buttonStyle(ZeusButtonStyle(.primary)).focusable()
                            .modifier(ConversationControlFocus(focus: focus, target: .init(entryID: entry.id, controlID: "settings")))
                        Button("Copy Setup Commands", action: copySetup).accessibilityLabel("Copy Setup Commands").buttonStyle(ZeusButtonStyle(.secondary)).focusable()
                            .modifier(ConversationControlFocus(focus: focus, target: .init(entryID: entry.id, controlID: "copySetup")))
                        if settings.talkHotKey.enabled, settings.talkHotKey.isValid {
                            Text("Press \(settings.talkHotKey.displayName) to talk to Zeus from any app.")
                                .zeusFont(.caption).environment(\.zeusFontChoice, .system).foregroundStyle(palette.secondaryText)
                        }
                    }
                } else { bodyText }
            }
            .onHover { ratingHovered = $0 }
            .modifier(OptionalRatingAccessibility(card: card, model: ratings))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(ConversationLayout.accessibilityLabel(entry, sessions: sessions))
            if let card, let ratings { MutedMessageReason(card: card, model: ratings) }
            if let card, card.response?.skipped == true {
                Text("Skipped").zeusFont(.caption).foregroundStyle(palette.secondaryText)
                    .accessibilityElement(children: .ignore).accessibilityLabel("Skipped")
            }
            if case .userAnswer(_, let response) = entry.content, response.device == .ios { Text("Answered on iPhone").zeusFont(.caption).foregroundStyle(palette.secondaryText) }
            if entry.outcome == .discarded {
                Text("Discarded").zeusFont(.caption).foregroundStyle(palette.secondaryText)
            }
            if entry.outcome == .sending {
                Text("Sending…").zeusFont(.caption).foregroundStyle(palette.secondaryText)
            }
            if entry.outcome == .unconfirmed {
                Text("Delivery status unavailable. Check with your assistant before sending again.")
                    .zeusFont(.caption).foregroundStyle(palette.secondaryText)
            }
            if case .delivery(let result) = entry.outcome {
                VStack(alignment: .trailing, spacing: 4) {
                    switch result {
                    case .delivered: EmptyView()
                    case .queued(let reason): Text(reason).foregroundStyle(palette.secondaryText)
                    case .failed(let reason):
                        // Retry sits on the caption's line when it fits, otherwise right under it.
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .firstTextBaseline, spacing: ZeusTheme.Spacing.s) { failedCaption(reason); retryButton }
                            VStack(alignment: .trailing, spacing: 4) { failedCaption(reason); retryButton }
                        }
                    }
                }.zeusFont(.caption).multilineTextAlignment(.trailing)
                    .frame(maxWidth: maxWidth, alignment: .trailing)
            }
        }.frame(maxWidth: .infinity, alignment: entry.isUser ? .trailing : .leading)
    }
    private func failedCaption(_ reason: String) -> some View {
        Text("Not sent: \(reason)").foregroundStyle(palette.destructive).fixedSize(horizontal: false, vertical: true)
    }
    private var retryButton: some View {
        Button("Retry") { Task { await model.retry(entryID: entry.id) } }.accessibilityLabel("Retry Message")
            .buttonStyle(ZeusButtonStyle(.secondary, size: .small)).focusable().disabled(model.isSending)
            .modifier(ConversationControlFocus(focus: focus, target: .init(entryID: entry.id, controlID: "retry")))
    }
    private func attachmentRow(_ attachment: Attachment) -> some View {
        AttachmentChip(attachment: attachment, muted: entry.isMuted || card.map { ratings?.isHeld($0) == true } == true, entryID: entry.id, threadFocus: focus)
    }
    private var card: Card? { if case .agentCard(let card) = entry.content { return card }; return nil }
    private var bodyText: some View {
        // D18: links and bold runs in the user's own bubble take its text color, so they read on `userBubble`.
        let markdown = ZeusMarkdown.attributed(entry.body, choice: settings.fontChoice, palette: entry.isUser ? palette.userBubbleText : palette)
        return MessageBodyView(markdown: markdown, active: isVisible && card?.kind == .message,
                               enabled: settings.typewriterEnabled, soundEnabled: settings.soundEnabled && !settings.isQuiet(at: Date()), reveal: model.revealer(cardID: entry.sourceCardID))
    }
    private func optionState(_ card: Card) -> ZeusOptionButtons.State {
        if entry.isMuted { return .closed }
        if card.status == .answered { return .answered(optionID: card.response?.optionID) }
        return .open(shortcuts: shortcuts)
    }

}

private struct ConversationControlFocus: ViewModifier {
    let focus: FocusState<ConversationControlTarget?>.Binding
    let target: ConversationControlTarget
    func body(content: Content) -> some View {
        content.focused(focus, equals: target).id(target)
    }
}

/// Only the latest bubble, bottom sentinel and activity row require document-space measurements.
private final class ConversationMeasurements {
    var viewport = ConversationViewport()
    var frames: [String: CGRect] = [:]
}
private struct ConversationThreadRow: Identifiable {
    let entry: ConversationEntry
    let previous: ConversationEntry?
    let first: Bool
    var id: String { entry.id }
}

/// Visibility changes update only these consumers, not the thread's data/row factory.
@MainActor @Observable final class ConversationVisibility {
    var ids: Set<String> = []
    var seenIDs: Set<String> = []
    var navigationIDs: Set<String> = []
    var awayFromLatest = false
    var jumpsReady = false
}

private struct ConversationVisibleBubble: View {
    let bubble: ConversationBubble
    let visibility: ConversationVisibility
    var body: some View {
        var current = bubble
        if let reveal = bubble.model.revealer(cardID: bubble.entry.sourceCardID), reveal.isRevealing {
            current.isVisible = bubble.isVisible && visibility.ids.contains(bubble.entry.id)
        }
        return current.equatable()
    }
}
private struct ConversationVisibleActivity: View {
    let presentation: ConversationActivityPresentation
    let visibility: ConversationVisibility
    let activity: SurfaceActivity
    var body: some View {
        ConversationActivityRow(presentation: presentation)
            .environment(\.zeusAnimationsActive, activity.conversation && visibility.ids.contains("assistantActivity"))
    }
}
private struct ConversationSeenTracker: View {
    let visibility: ConversationVisibility
    let entries: [ConversationEntry]
    let store: CardStore
    let panel: ConversationPanelState
    let activity: SurfaceActivity
    private struct Request: Equatable { let ids: Set<String>; let open: Bool }
    var body: some View {
        Color.clear.frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
            .task(id: Request(ids: visibility.seenIDs, open: panel.isVisible && activity.conversation && !panel.document.isOpen)) {
                guard panel.isVisible && activity.conversation && !panel.document.isOpen else { return }
                let ids = visibility.seenIDs
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                guard panel.isVisible && activity.conversation && !panel.document.isOpen else { return }
                for entry in entries where ids.contains(entry.id) && visibility.seenIDs.contains(entry.id) && !entry.isUser {
                    store.markSeen(id: entry.sourceCardID)
                }
            }
    }
}
/// Only this small overlay observes scrolling visibility; rows do not rebuild for pill changes.
struct ConversationJumpOverlay: View {
    let edge: ZeusJumpPillCluster.Edge
    let visibility: ConversationVisibility
    let entries: [ConversationEntry]
    let store: CardStore
    let questions: [String]
    let lastQuestion: String?
    let atBottom: Bool
    let pending: Bool
    let panel: ConversationPanelState
    let unread: (String) -> Void
    let latest: () -> Void
    let question: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.zeusAnimationsActive) private var animationsActive
    var body: some View {
        let state = ConversationJumpState.make(entries: entries, visible: visibility.navigationIDs,
            seen: store.seenIDs, questions: questions, after: lastQuestion, atBottom: atBottom,
            pending: pending, awayFromLatest: visibility.awayFromLatest)
        let ready = panel.isVisible && visibility.jumpsReady
        let pills = ready ? items(state) : []
        Group {
            if !pills.isEmpty {
                ZeusJumpPillCluster(edge: edge, items: pills)
                    .transition(ZeusJumpPillCluster.transition(edge: edge, reduceMotion: reduceMotion, animationsActive: animationsActive))
            }
        }
            .animation(reduceMotion || !animationsActive ? nil : .easeOut(duration: ZeusJumpPillCluster.duration), value: pills.map(\.id))
            .onChange(of: ready && state.showsLatest, initial: true) { _, visible in
                #if DEBUG || ZEUS_PERFORMANCE_PROBE
                if edge == .bottom { panel.latestButtonVisibleForDiagnostics = visible }
                #endif
            }
    }
    private func items(_ state: ConversationJumpState) -> [ZeusJumpPillCluster.Item] {
        var result: [ZeusJumpPillCluster.Item] = []
        if edge == .top, let first = state.unreadAbove.first {
            result.append(.init(.unread(state.unreadAbove.count), onMarkRead: { store.markSeen(ids: Set(state.unreadAbove)) },
                                action: { unread(first) }))
        }
        if edge == .bottom && state.showsLatest { result.append(.init(.latest(newCount: state.newBelow), action: latest)) }
        if let direction = state.questionDirection,
           (edge == .top && direction == .up) || (edge == .bottom && direction == .down) {
            result.append(.init(.question(count: state.questionCount, direction: direction == .up ? .up : .down), action: question))
        }
        return result
    }
}

/// Managed onboarding keeps the first conversation message reserved for the agent's check-in.
private struct ManagedEmptyThread: View {
    let onOpenSettings: () -> Void
    @Environment(\.zeusPalette) private var palette
    var body: some View {
        VStack(spacing: ZeusTheme.Spacing.s) {
            Text("Meet your assistant").zeusFont(.button).foregroundStyle(palette.title)
            Text("Choose a folder and an agent in Settings. Zeus runs it for you; its check-in appears here.")
                .zeusFont(.caption).foregroundStyle(palette.secondaryText)
            Button("Set Up Your Assistant", action: onOpenSettings).accessibilityLabel("Set Up Your Assistant").buttonStyle(ZeusButtonStyle(.primary, size: .small))
        }.multilineTextAlignment(.center)
    }
}
