import Foundation
import ZeusProtocol
import ZeusLink

extension AppControlError {
    /// File/argument/updater explanations are already user-facing; preserve them verbatim.
    var agentMessage: String {
        switch self {
        case .disabled(let setting): "disabled: \(setting)"
        case .unknownID(let id): "Unknown id: \(id)"
        case .invalidFile(let message), .invalidArgument(let message), .updaterUnavailable(let message): message
        case .noKnownUpdate: "zeus_install_update requires zeus_check_for_updates to report this exact version in this session."
        }
    }
}

extension ZeusRuntime {
    static let appToolNames: Set<String> = ["zeus_app_state", "zeus_set_character", "zeus_create_character", "zeus_set_theme", "zeus_create_theme", "zeus_move", "zeus_set_size", "zeus_hide", "zeus_set_appearance", "zeus_check_for_updates", "zeus_install_update", "zeus_get_learnings"]

    func callAppTool(_ name: String, args: ToolArguments, sessionKey: String, deferResultCommit: Bool) async throws -> ToolResult {
        if name == "zeus_app_state" { return result(try JSONValue.from(appControl.appControlState)) }
        if name == "zeus_get_learnings" {
            reconcileOutboundLearningPolicy()
            if let id = try args.string("id") {
                let record = try fetchedDelivery(id: id, sessionKey: sessionKey, learning: true)
                return result(["delivery": try JSONValue.from(record.delivery)])
            }
            let items = learnings.learningsEnabled ? learnings.unreadLearnings().filter { !learningWasErased($0.id) && ledger?.record(id: $0.id)?.delivery.ackedAt == nil } : []
            // Keep both text and structured copies within the link's 4 MiB frame limit.
            var batch: [Learning] = [], bytes = 1024
            let token = generation
            for original in items {
                let item = await learningForSending(original)
                guard running, generation == token, learnings.learningsEnabled, !learningWasErased(original.id),
                      learnings.unreadLearnings().contains(where: { $0.id == original.id }) else { throw CancellationError() }
                let json = try JSONValue.from(item), raw = try ZeusJSON.encoder().encode(json)
                let escaped = try ZeusJSON.encoder().encode(JSONValue.string(String(decoding: raw, as: UTF8.self)))
                guard bytes + raw.count + escaped.count < 4 * 1024 * 1024 else {
                    if batch.isEmpty { throw ToolArgumentError("Learning is too large for one result; it remains unread.") }; break
                }
                batch.append(item); bytes += raw.count + escaped.count
            }
            let output = result(["learnings": .array(try batch.map(JSONValue.from))])
            if !deferResultCommit, !output.isError, let last = batch.last {
                learnings.markLearningsRead(through: last.id)
                recordLearningToolReceipts(try batch.map(JSONValue.from), sessionKey: sessionKey)
            }
            return output
        }
        if name == "zeus_check_for_updates" {
            guard appControl.assistantMayControlApp else { throw AppControlError.disabled(setting: "Let my assistant control Zeus") }
            let token = generation
            let check = try await appControl.checkForUpdates()
            guard running, generation == token else { throw CancellationError() }
            if check.available, let version = check.version { checkedUpdateVersions[sessionKey, default: []].insert(version) }
            return result(try JSONValue.from(check))
        }
        guard appControl.assistantMayControlApp else { throw AppControlError.disabled(setting: "Let my assistant control Zeus") }
        if name == "zeus_install_update" {
            guard appControl.assistantMayInstallUpdates else { throw AppControlError.disabled(setting: "Let my assistant install updates") }
            let version = try args.requiredString("version")
            guard checkedUpdateVersions[sessionKey]?.contains(version) == true else { throw AppControlError.noKnownUpdate }
            return try await installAppUpdate(version: version, sessionKey: sessionKey)
        }
        let previous = appControl.appControlState.characterID
        let change: AppChange
        switch name {
        case "zeus_set_character": change = try appControl.setCharacter(id: args.requiredString("id"))
        case "zeus_create_character": change = try appControl.createCharacter(name: args.requiredString("name"), json: Data(args.requiredString("json").utf8))
        case "zeus_set_theme": change = try appControl.setTheme(id: args.requiredString("id"))
        case "zeus_create_theme": change = try appControl.createTheme(name: args.requiredString("name"), json: Data(args.requiredString("json").utf8))
        case "zeus_move": change = try appControl.move(to: args.placement())
        case "zeus_set_size":
            let size = try args.requiredString("size")
            guard ["small", "medium", "large"].contains(size) else { throw AppControlError.invalidArgument("size must be small, medium or large") }
            change = try appControl.setSize(size)
        case "zeus_hide":
            let minutes = try args.integer("minutes", range: 1...720), until = try args.string("until")
            guard (minutes != nil) != (until != nil), until == nil || until == "tomorrow" else { throw AppControlError.invalidArgument("zeus_hide requires exactly one duration: minutes 1–720 or until: tomorrow. Indefinite hide is forbidden.") }
            change = try appControl.hide(minutes: minutes, untilTomorrow: until != nil)
        case "zeus_set_appearance":
            let patch = try args.appearancePatch()
            appQuestionIDs = appQuestionIDs.filter { cards.card(id: $0)?.status == .open }
            if patch.quietHours == false, !appQuestionIDs.isEmpty {
                throw AppControlError.invalidArgument("Cannot turn quiet hours off while a question is pending.")
            }
            change = try appControl.setAppearance(patch)
        default: throw ToolArgumentError("Unknown tool: \(name)")
        }
        let trackedChange = learningTrackedChange(change)
        if let recorder = cards as? any AppChangeRecording { recorder.recordAppChange(trackedChange) }
        else { cards.recordAppChange(trackedChange) }
        if name == "zeus_set_character" { return result(["ok": true, "previous": .string(previous), "current": .string(appControl.appControlState.characterID)]) }
        return result(["ok": true, "summary": .string(change.summary)])
    }

    private func installAppUpdate(version: String, sessionKey: String) async throws -> ToolResult {
        guard installingSessions.insert(sessionKey).inserted else { throw AppControlError.invalidArgument("An update is already being installed for this session.") }
        let token = generation
        defer { if generation == token { installingSessions.remove(sessionKey) } }
        try checkCardPersistence()
        let now = clock.now
        cards.add(Card(kind: .message, body: "Updating to \(version) — back in a few seconds", sessionKey: sessionKey, createdAt: now, updatedAt: now))
        try checkCardPersistence()
        do {
            let deadline = clock.now.addingTimeInterval(60)
            while updateIsBusy(sessionKey: sessionKey), clock.now < deadline {
                try await clock.sleep(until: min(deadline, clock.now.addingTimeInterval(0.25)))
                guard running, generation == token else { throw CancellationError() }
            }
            try Task.checkCancellation()
            guard running, generation == token else { throw CancellationError() }
            guard appControl.assistantMayControlApp, appControl.assistantMayInstallUpdates else {
                throw AppControlError.disabled(setting: "Assistant update installation")
            }
            try await appControl.installUpdate(version: version)
            return result(["ok": true, "version": .string(version)])
        } catch {
            guard running, generation == token, !(error is CancellationError) else { throw error }
            let message = (error as? AppControlError)?.agentMessage ?? error.localizedDescription
            pendingUpdateErrors[sessionKey] = message
            cards.add(Card(kind: .message, body: "Couldn't update to \(version): \(message)", priority: .low, sessionKey: sessionKey, createdAt: clock.now, updatedAt: clock.now))
            throw error
        }
    }

    func updateIsBusy(sessionKey: String) -> Bool {
        if (activeToolCalls[sessionKey] ?? 0) > 1 { return true }
        if waiters.values.contains(where: { $0.sessionKey == sessionKey }) { return true }
        if sends.keys.contains(where: { ledger?.record(id: $0)?.delivery.sessionKey == sessionKey }) { return true }
        if (ledger?.records ?? []).contains(where: { $0.isPending && $0.delivery.sessionKey == sessionKey && $0.delivery.meta["tmux_paste_destination"] != nil }) { return true }
        if case .blocked = managedStatus { return true }
        return false
    }

    func notifyLearning(_ learning: Learning) {
        guard running, learnings.learningsEnabled else { return }
        let token = generation
        // Redact once for all recipients, so the ledger records each recipient's exact payload.
        Task { [weak self] in
            guard let self else { return }
            let safe = await self.learningForSending(learning)
            guard self.running, self.generation == token, self.learnings.learningsEnabled, !self.learningWasErased(learning.id),
                  self.learnings.unreadLearnings().contains(where: { $0.id == learning.id }) else { return }
            self.enqueueLearning(safe)
            let payload = BridgeLearning(id: safe.id, kind: safe.kind == .digest ? .digest : .moment, text: safe.text)
            for session in self.bridges.values where session.sessionKey == self.assistantTarget && session.hello.capabilities.channel && session.hello.capabilities.learningNotifications {
                Task { [weak self] in
                    guard let self, self.running, self.generation == token, self.learnings.learningsEnabled, !self.learningWasErased(learning.id),
                          self.bridges[session.sessionKey]?.id == session.id, self.assistantTarget == session.sessionKey else { return }
                    self.reconcileOutboundLearningPolicy()
                    guard !self.learningWasErased(learning.id) else { return }
                    // A lost announcement never consumes a learning; polling retains it.
                    do {
                        try await session.notifyLearning(payload)
                        guard self.running, self.generation == token else { return }
                        // A notification write is not evidence that the model read it.
                    } catch { /* No fabricated receipt for an unsuccessful notification. */ }
                }
            }
        }
    }
}

extension ToolArguments {
    func integer(_ key: String, range: ClosedRange<Int>) throws -> Int? {
        guard let value = try number(key) else { return nil }
        guard value.rounded() == value, value >= Double(range.lowerBound), value <= Double(range.upperBound) else { throw AppControlError.invalidArgument("\(key) must be an integer from \(range.lowerBound) to \(range.upperBound)") }
        return Int(value)
    }
    func placement() throws -> AvatarPlacement {
        switch values["position"] {
        case .string("top-left"): return .topLeft
        case .string("top-right"): return .topRight
        case .string("bottom-left"): return .bottomLeft
        case .string("bottom-right"): return .bottomRight
        case .string("near-active-window"): return .nearActiveWindow
        case .object(let fields):
            guard Set(fields.keys) == ["screen", "x", "y"] else { throw AppControlError.invalidArgument("position coordinates require only screen, x and y") }
            let point = try ToolArguments(.object(fields))
            guard let screen = try point.integer("screen", range: 0...Int(Int32.max)), let x = try point.number("x"), let y = try point.number("y") else { throw AppControlError.invalidArgument("position coordinates require screen, x and y") }
            return .point(screen: screen, x: x, y: y)
        default: throw AppControlError.invalidArgument("position must be a named corner, near-active-window or {screen, x, y}")
        }
    }
    func appearancePatch() throws -> AppearancePatch {
        guard !values.isEmpty else { throw AppControlError.invalidArgument("zeus_set_appearance needs at least one appearance setting") }
        if let font = try string("font"), !["pixel", "system"].contains(font) { throw AppControlError.invalidArgument("font must be pixel or system") }
        func boolean(_ key: String) throws -> Bool? { values[key] == nil ? nil : try bool(key, default: false) }
        return try .init(ghostMode: boolean("ghost_mode"), ghostOpacity: number("ghost_opacity"), ghostDelaySeconds: number("ghost_delay_seconds"),
            popupSound: boolean("popup_sound"), popupSoundName: string("popup_sound_name"), font: string("font"), panelWidth: number("panel_width"),
            quietHours: boolean("quiet_hours"), quietStartHour: integer("quiet_start_hour", range: 0...23), quietEndHour: integer("quiet_end_hour", range: 0...23))
    }
}

/// Fail closed until the composition root supplies the app-owned capability.
@MainActor final class UnavailableAppControl: AppControlling {
    var assistantMayControlApp: Bool { false }
    var assistantMayInstallUpdates: Bool { false }
    var appControlState: AppControlState { .init(version: "", build: "", characterID: "", themeID: "", size: "medium", screen: 0, position: [:], screens: [], panelOpen: false, hidden: false, quietHoursActive: false, ghostMode: false, userIdleSeconds: 0, formats: ["character": "docs/design/SPRITE_FORMAT.md", "theme": "docs/design/THEME_FORMAT.md"]) }
    func setCharacter(id: String) throws -> AppChange { throw AppControlError.disabled(setting: "App controls unavailable") }
    func createCharacter(name: String, json: Data) throws -> AppChange { throw AppControlError.disabled(setting: "App controls unavailable") }
    func setTheme(id: String) throws -> AppChange { throw AppControlError.disabled(setting: "App controls unavailable") }
    func createTheme(name: String, json: Data) throws -> AppChange { throw AppControlError.disabled(setting: "App controls unavailable") }
    func move(to placement: AvatarPlacement) throws -> AppChange { throw AppControlError.disabled(setting: "App controls unavailable") }
    func setSize(_ size: String) throws -> AppChange { throw AppControlError.disabled(setting: "App controls unavailable") }
    func hide(minutes: Int?, untilTomorrow: Bool) throws -> AppChange { throw AppControlError.disabled(setting: "App controls unavailable") }
    func setAppearance(_ patch: AppearancePatch) throws -> AppChange { throw AppControlError.disabled(setting: "App controls unavailable") }
    func checkForUpdates() async throws -> UpdateCheckResult { throw AppControlError.updaterUnavailable("App updater unavailable") }
    func installUpdate(version: String) async throws { throw AppControlError.disabled(setting: "App controls unavailable") }
}
@MainActor final class EmptyLearnings: LearningsProviding {
    var learningsEnabled: Bool { false }
    var onNewLearning: ((Learning) -> Void)?
    func unreadLearnings() -> [Learning] { [] }
    func markLearningsRead(through id: String) {}
}
