import Foundation
import Testing
import ZeusProtocol
import ZeusLink
@testable import Zeus

@MainActor final class FakeAppControl: AppControlling {
    var assistantMayControlApp = true, assistantMayInstallUpdates = true
    var appControlState = AppControlState(version: "1", build: "2", characterID: "zeus", themeID: "day", size: "medium", screen: 0,
        position: ["x": 10, "y": 20], screens: [["width": 1200, "height": 800, "scale": 2]], panelOpen: false, hidden: false,
        quietHoursActive: false, ghostMode: false, userIdleSeconds: 30, formats: ["character": "character.md", "theme": "theme.md"])
    var calls: [String] = [], placements: [AvatarPlacement] = [], patches: [AppearancePatch] = [], files: [Data] = [], hides: [(Int?, Bool)] = []
    var failure: AppControlError?, installFailure: AppControlError?
    var check = UpdateCheckResult(available: true, version: "2.0", notes: "New")
    var installs: [String] = [], undos = 0
    func change(_ text: String) throws -> AppChange {
        if let failure { throw failure }; calls.append(text)
        return .init(summary: text, undoTitle: "Undo", undo: { [weak self] in self?.undos += 1 })
    }
    func setCharacter(id: String) throws -> AppChange {
        guard id != "missing" else { throw AppControlError.unknownID(id) }
        let c = try change("character"); appControlState.characterID = id; return c
    }
    func createCharacter(name: String, json: Data) throws -> AppChange { let c = try change("create-character"); files.append(json); return c }
    func setTheme(id: String) throws -> AppChange { try change("theme") }
    func createTheme(name: String, json: Data) throws -> AppChange { let c = try change("create-theme"); files.append(json); return c }
    func move(to placement: AvatarPlacement) throws -> AppChange { let c = try change("move"); placements.append(placement); return c }
    func setSize(_ size: String) throws -> AppChange { try change("size:" + size) }
    func hide(minutes: Int?, untilTomorrow: Bool) throws -> AppChange { let c = try change("hide"); hides.append((minutes, untilTomorrow)); return c }
    func setAppearance(_ patch: AppearancePatch) throws -> AppChange { let c = try change("appearance"); patches.append(patch); return c }
    func checkForUpdates() async throws -> UpdateCheckResult { if let failure { throw failure }; return check }
    func installUpdate(version: String) async throws { if let installFailure { throw installFailure }; installs.append(version) }
}
@MainActor final class FakeLearnings: LearningsProviding {
    var learningsEnabled = true
    var onNewLearning: ((Learning) -> Void)?
    var items: [Learning] = [], readIDs: [String] = []
    func unreadLearnings() -> [Learning] { items }
    func markLearningsRead(through id: String) {
        readIDs.append(id)
        if let index = items.firstIndex(where: { $0.id == id }) { items.removeFirst(index + 1) }
    }
    func add(_ learning: Learning) { items.append(learning); onNewLearning?(learning) }
}

@MainActor struct AppControlTests {
    @Test func everyControlMapsToTheSeamAndRecordsItsUndo() async throws {
        let app = FakeAppControl(), f = try RuntimeFixture(appControl: app); defer { f.stop() }
        #expect(await f.call("zeus_app_state").structured == (try JSONValue.from(app.appControlState)))
        let calls: [(String, JSONValue)] = [
            ("zeus_set_character", ["id": "wisp"]), ("zeus_create_character", ["name": "New", "json": "{ character }"]),
            ("zeus_set_theme", ["id": "night"]), ("zeus_create_theme", ["name": "New", "json": "{ theme }"]),
            ("zeus_move", ["position": "near-active-window"]), ("zeus_move", ["position": ["screen": 1, "x": -5, "y": 20]]),
            ("zeus_set_size", ["size": "large"]), ("zeus_hide", ["minutes": 30]), ("zeus_hide", ["until": "tomorrow"]),
            ("zeus_set_appearance", ["ghost_mode": true, "ghost_opacity": 0.4, "ghost_delay_seconds": 8, "popup_sound": false,
                "popup_sound_name": "Pop", "font": "system", "panel_width": 500, "quiet_hours": true, "quiet_start_hour": 23, "quiet_end_hour": 7])]
        for (tool, args) in calls { #expect(!(await f.call(tool, args)).isError) }
        #expect(f.cards.appChanges.count == calls.count && f.cards.values.isEmpty)
        #expect(app.placements == [.nearActiveWindow, .point(screen: 1, x: -5, y: 20)])
        #expect(app.files == [Data("{ character }".utf8), Data("{ theme }".utf8)])
        #expect(app.hides.count == 2 && app.hides[0].0 == 30 && app.hides[1].1)
        #expect(app.patches == [.init(ghostMode: true, ghostOpacity: 0.4, ghostDelaySeconds: 8, popupSound: false,
            popupSoundName: "Pop", font: "system", panelWidth: 500, quietHours: true, quietStartHour: 23, quietEndHour: 7)])
        f.cards.appChanges[0].undo(); #expect(app.undos == 1)
        #expect(!(await f.call("zeus_check_for_updates")).isError)
        #expect(!(await f.call("zeus_install_update", ["version": "2.0"])).isError)
        #expect(app.installs == ["2.0"] && f.cards.values.last?.body == "Updating to 2.0 — back in a few seconds")
    }

    @Test func disabledUnknownAndFileErrorsNeverPostChangesOrChat() async throws {
        let app = FakeAppControl(), f = try RuntimeFixture(appControl: app); defer { f.stop() }
        app.assistantMayControlApp = false
        for tool in ZeusRuntime.appToolNames.subtracting(["zeus_app_state", "zeus_get_learnings"]) {
            let reply = await f.call(tool)
            #expect(reply.isError && reply.text.contains("disabled"))
        }
        app.assistantMayControlApp = true
        #expect((await f.call("zeus_set_character", ["id": "missing"])).text.contains("Unknown id: missing"))
        app.failure = .invalidFile("Frame 5 is missing its pixels — keep this exact message.")
        let result = await f.call("zeus_create_character", ["name": "Bad", "json": "broken"])
        #expect(result.isError && result.structured?["error"] == "Frame 5 is missing its pixels — keep this exact message.")
        #expect(f.cards.appChanges.isEmpty && f.cards.values.isEmpty)
    }

    @Test func neverListAndDurationValidationRejectWithoutMutation() async throws {
        let app = FakeAppControl(), f = try RuntimeFixture(appControl: app); defer { f.stop() }
        for args: JSONValue in [[:], ["minutes": 0], ["minutes": 721], ["minutes": 1.5], ["until": "forever"], ["minutes": 1, "until": "tomorrow"]] {
            #expect((await f.call("zeus_hide", args)).isError)
        }
        for args: JSONValue in [["permission_mode": "yolo"], ["learn_from_me": true], ["launch_at_login": true], ["quiet_start_hour": 25]] {
            #expect((await f.call("zeus_set_appearance", args)).isError)
        }
        #expect((await f.call("zeus_install_update", ["version": "2.0"])).isError)
        _ = await f.call("zeus_check_for_updates", session: "claude:/other")
        #expect((await f.call("zeus_install_update", ["version": "2.0"])).isError, "Another session's check cannot authorize this caller")
        _ = await f.call("zeus_ask", ["text": "Pending?", "wait_seconds": 0])
        #expect((await f.call("zeus_set_appearance", ["quiet_hours": false])).isError)
        #expect((await f.call("zeus_set_appearance", ["quiet_hours": false], session: "claude:/other")).isError)
        #expect(f.cards.values.count == 1 && app.calls.isEmpty)
    }

    @Test func installWaitsForItsDeliveryButNotAnotherSessionsAndFailureIsReportedOnce() async throws {
        let app = FakeAppControl(), f = try RuntimeFixture(appControl: app); defer { f.stop() }
        f.connect(); f.routing.assistantSessionKey = "claude:/assistant"; f.connector.hold = true
        let send = Task { await f.runtime.sendUserMessage("In flight") }
        try await eventually { !f.connector.waits.isEmpty }
        _ = await f.call("zeus_check_for_updates")
        let install = Task { await f.call("zeus_install_update", ["version": "2.0"]) }
        try await eventually { f.cards.values.count == 1 && !f.clock.pendingDeadlines.isEmpty }
        #expect(app.installs.isEmpty)
        f.connector.release(); _ = await send.value
        f.clock.advance(1)
        #expect(!(await install.value).isError && app.installs == ["2.0"])
        app.installFailure = .updaterUnavailable("The downloaded archive could not be verified.")
        #expect((await f.call("zeus_install_update", ["version": "2.0"])).isError)
        #expect(f.cards.values.last?.body.contains("archive could not be verified") == true)
        #expect(!(await f.call("zeus_app_state", session: "claude:/other")).isError)
        #expect((await f.call("zeus_app_state")).structured?["error"] == "The downloaded archive could not be verified.")
        #expect(!(await f.call("zeus_app_state")).isError)
    }

    @Test func learningsAreOrderedAndOnlyACommittedResultMarksThemRead() async throws {
        let learning = FakeLearnings(), f = try RuntimeFixture(learnings: learning); defer { f.stop() }
        learning.items = [.init(id: "one", kind: .digest, createdAt: f.clock.now, text: "A focused day."), .init(id: "two", kind: .moment, createdAt: f.clock.now.addingTimeInterval(1), text: "Back from a break.")]
        let unwritten = await f.runtime.callTool("zeus_get_learnings", arguments: [:], sessionKey: "claude:/assistant", deferResultCommit: true)
        #expect(learning.readIDs.isEmpty && unwritten.structured?["learnings"]?[0]?["id"] == "one")
        #expect(unwritten.structured?["learnings"]?[1]?["id"] == "two")
        let client = BridgeClient(socketPath: f.runtime.socketPath), hello = BridgeHello(agent: .claude, pid: 5, ppid: 7, cwd: "/fixture", client: .init(name: "Test", version: "1"), capabilities: .init(channel: true, toolResultWritten: true), parentStartTime: 3)
        do {
            _ = try await client.start(hello: hello, onPush: { _ in })
            let reply = try await client.requestTool(name: "zeus_get_learnings")
            #expect(learning.readIDs.isEmpty)
            try await client.reportToolResultWritten(callID: reply.callID)
            try await eventually { learning.readIDs == ["two"] }
            #expect(learning.items.isEmpty)
            learning.learningsEnabled = false
            learning.items = [.init(id: "private", kind: .moment, createdAt: f.clock.now, text: "Not shared")]
            #expect((await f.call("zeus_get_learnings")).structured?["learnings"] == [])
            #expect(learning.readIDs == ["two"])
            await client.stop()
        } catch { await client.stop(); throw error }
    }

    @Test(arguments: [false, true])
    func managedBlockingDefersInstallationUntilClearOrTheSixtySecondBound(exhaustWait: Bool) async throws {
        let app = FakeAppControl(), f = try ManagedDeliveryFixture(appControl: app); defer { f.cleanup() }
        try await f.start(); try await f.idle()
        let key = try #require(f.managed.controller.sessionKey)
        await f.managed.host.setSnapshot(try managedSnapshot("claude-blocked-permission"))
        for _ in 0..<2 { f.managed.controller.refresh(); try await f.managed.settle() }
        _ = await f.runtime.callTool("zeus_check_for_updates", arguments: [:], sessionKey: key)
        let install = Task { await f.runtime.callTool("zeus_install_update", arguments: ["version": "2.0"], sessionKey: key) }
        try await eventually { f.cards.values.contains { $0.body.hasPrefix("Updating to") } && (f.runtime.activeToolCalls[key] ?? 0) == 1 }
        #expect(app.installs.isEmpty && f.runtime.updateIsBusy(sessionKey: key))
        if !exhaustWait {
            await f.managed.host.setSnapshot(try managedSnapshot("claude-idle"))
            f.managed.controller.refresh(); try await f.managed.settle()
        }
        f.managed.clock.advance(exhaustWait ? 60 : 1)
        #expect(!(await install.value).isError && app.installs == ["2.0"])
    }

    @Test func otherSessionWorkAndChecksAreIsolatedAndSwitchRevocationStopsInstall() async throws {
        let app = FakeAppControl(), f = try RuntimeFixture(appControl: app); defer { f.stop() }
        f.connect(); f.routing.assistantSessionKey = "claude:/assistant"; f.connector.hold = true
        let send = Task { await f.runtime.sendUserMessage("In flight") }
        try await eventually { !f.connector.waits.isEmpty }
        _ = await f.call("zeus_check_for_updates", session: "claude:/other")
        #expect(!(await f.call("zeus_install_update", ["version": "2.0"], session: "claude:/other")).isError)
        #expect(app.installs == ["2.0"])
        _ = await f.call("zeus_check_for_updates")
        let install = Task { await f.call("zeus_install_update", ["version": "2.0"]) }
        try await eventually { f.cards.values.count == 2 }
        app.assistantMayInstallUpdates = false
        f.connector.release(); _ = await send.value; f.clock.advance(1)
        #expect((await install.value).isError && app.installs == ["2.0"])
        #expect(f.cards.values.last?.body.contains("disabled") == true)
    }

    @Test func cardsFromOtherSessionsAndNativePromptCardsCannotBeChangedOrDismissed() async throws {
        let f = try RuntimeFixture(); defer { f.stop() }
        let foreign = Card(kind: .message, body: "Private other session", sessionKey: "claude:/other")
        let native = Card(id: ZeusRuntime.managedCardPrefix + "native", kind: .content, body: "A permission prompt", sessionKey: "claude:/assistant")
        f.cards.add(foreign); f.cards.add(native)
        for card in [foreign, native] {
            #expect((await f.call("zeus_update_card", ["card_id": .string(card.id), "text": "Hijacked"])).isError)
            #expect((await f.call("zeus_dismiss", ["card_id": .string(card.id)])).isError)
            #expect(f.cards.card(id: card.id) == card)
        }
        try f.runtime.ledger?.insert(.init(delivery: .init(id: "d_handoff", kind: .reply, cardID: foreign.id, sessionKey: "claude:/assistant", content: "An earlier-session answer")))
        #expect(!(await f.call("zeus_update_card", ["card_id": .string(foreign.id), "append_text": "\nHandled in the receiving session"])).isError)
        #expect(f.cards.card(id: foreign.id)?.body.hasSuffix("Handled in the receiving session") == true)
    }

    @Test func newLearningNotifiesOnlyOptedInChannelsAndNeverConsumesThePoll() async throws {
        let store = FakeLearnings(), f = try RuntimeFixture(learnings: store); defer { f.stop() }
        var received: [[BridgeLearning]] = [[], [], []]
        var clients: [BridgeClient] = []
        do {
            for i in 0..<3 {
                let client = BridgeClient(socketPath: f.runtime.socketPath); clients.append(client)
                let hello = BridgeHello(agent: i == 1 ? .codex : .claude, pid: 20 + i, ppid: 10 + i, cwd: "/fixture",
                    client: .init(name: "Test", version: "1"), capabilities: .init(channel: i != 1, learningNotifications: i != 2), parentStartTime: 3)
                _ = try await client.start(hello: hello, onPush: { _ in }, onLearning: { item in await MainActor.run { received[i].append(item) } })
            }
            try await eventually { f.runtime.sessions.count == 3 }
            store.add(.init(id: "l_1", kind: .moment, createdAt: f.clock.now, text: "Back from a break."))
            try await eventually { received[0].count == 1 }
            #expect(received[0][0] == .init(id: "l_1", kind: .moment, text: "Back from a break."))
            #expect(received[1].isEmpty && received[2].isEmpty && store.readIDs.isEmpty)
            #expect(store.unreadLearnings().count == 1)
            store.learningsEnabled = false
            store.add(.init(id: "l_private", kind: .digest, createdAt: f.clock.now, text: "Not shared"))
            try await Task.sleep(for: .milliseconds(20))
            #expect(received[0].count == 1)
            for client in clients { await client.stop() }
        } catch { for client in clients { await client.stop() }; throw error }
        f.runtime.stop(); #expect(store.onNewLearning == nil)
    }
}
