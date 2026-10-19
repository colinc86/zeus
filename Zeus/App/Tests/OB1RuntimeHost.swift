#if OB1_PROBE_HOST
import AppKit
import Foundation
import SwiftUI
import ZeusDesign
import ZeusProtocol

@MainActor private struct OB1NoCredentials: OpenCodePasswordStoring {
    func read() -> String? { nil }
    func save(_ password: String?) {}
}
private struct OB1PrivateRunner: ProcessRunning {
    let socket: String
    let environment: [String: String]
    func run(executable: URL, arguments: [String], input: Data?) async throws -> ProcessResult {
        guard socket.contains("/zob1_"), let i = arguments.firstIndex(of: "-S"), arguments.indices.contains(i + 1),
              arguments[i + 1] == socket else { throw ManagedSessionError.ownershipChanged }
        return try await FoundationProcessRunner().run(executable: executable, arguments: arguments, input: input, environment: environment)
    }
}
@MainActor private final class OB1Context {
    let root: URL
    let shell: ShellController
    let runtime: ZeusRuntime
    let controller: ManagedSessionController
    let began = Date()
    let timeline: FileHandle
    private var previous: Data?
    init(root: URL, bridge: URL, claude: URL, tmux: URL) throws {
        self.root = root
        let environment = ProcessInfo.processInfo.environment
        guard root.path.contains("/zob1_"), environment["HOME"] == root.appendingPathComponent("home").path,
              URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath() == root.appendingPathComponent("home").resolvingSymlinksInPath() else {
            throw ManagedSessionError.command("OB1 refused a non-private HOME")
        }
        guard let defaults = UserDefaults(suiteName: root.appendingPathComponent("home/Library/Preferences/zeus-ob1-" + root.lastPathComponent).path) else { throw ManagedSessionError.invalidState }
        let settings = AppSettings(defaults: defaults, userDirectory: root.appendingPathComponent("home/Library/Application Support/Zeus/Characters"), passwordStore: OB1NoCredentials())
        // The private host uses scoped native actions, never the human's global shortcut.
        settings.talkHotKey.enabled = false
        let cards = CardStore(fileURL: root.appendingPathComponent("cards.json"))
        shell = ShellController(defaults: defaults, cards: cards, settings: settings)
        let socket = root.appendingPathComponent("tmux.sock").path
        controller = ManagedSessionController(configuration: { settings.managedSession }, stateURL: root.appendingPathComponent("managed.json"),
            bridge: bridge, bridgeSocket: root.appendingPathComponent("bridge.sock").path,
            executables: .init(tmux: tmux, agents: [.claude: claude]),
            hosting: ManagedTmux(executable: tmux, environment: environment, testSocket: socket), environment: environment,
            isolatedSocket: socket, resourceDirectory: bridge.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources"))
        runtime = ZeusRuntime(cards: cards, status: shell.status, characters: settings, routing: settings,
            socketPath: root.appendingPathComponent("bridge.sock").path, ledgerURL: root.appendingPathComponent("deliveries.json"),
            connectors: [ChannelDeliveryConnector(), TmuxConnector(executable: tmux, runner: OB1PrivateRunner(socket: socket, environment: environment))],
            managedController: controller, appControl: shell.appControl, learnings: shell.learn.learnings)
        // Match AppDelegate order; injected runtime/controller are the private-fixture boundary.
        shell.start()
        try runtime.start(); shell.messaging.runtime = runtime
        shell.managed.createFolder = { [weak runtime] in
            guard let runtime else { throw CancellationError() }; return try runtime.createDefaultFolder()
        }
        shell.managed.refreshAvailability()
        let url = root.appendingPathComponent("timeline.jsonl")
        if !FileManager.default.fileExists(atPath: url.path) { try Data().write(to: url) }
        timeline = try FileHandle(forWritingTo: url); try timeline.seekToEnd()
    }
    var conversationWindow: NSWindow? { NSApp.windows.first { $0.title == "Zeus conversation" } }
    func state() -> [String: JSONValue] {
        shell.status.tick()
        let cards = shell.cards, settings = shell.settings
        let activity = ConversationActivityPresentation.make(shell.messaging.assistantActivity, panelVisible: shell.cardPanelState.isVisible,
            managedStatus: runtime.managedStatus, managedSessionKey: controller.sessionKey)
        let strip = StatusStripState.make(cards: .init(values: cards.cards, seen: cards.seenIDs, outgoing: cards.outgoingStates),
            status: .init(avatar: shell.status.presentation), managed: .init(enabled: shell.managed.enabled, isOff: shell.managed.assistantIsOff(connectedSessionCount: runtime.sessions.count), status: runtime.managedStatus,
                hasTerminal: controller.managedAttachCommand != nil, canStartNew: shell.managed.canStart), activity: activity)
        return ["avatar": .string(shell.status.state.rawValue), "menu": .string(shell.menuStatus), "strip": .string(strip.sentence),
            "managed": .string(String(describing: runtime.managedStatus)), "enabled": .bool(shell.managed.enabled),
            "at_bottom": .bool(shell.cardPanelState.atBottom), "viewport": .string(String(describing: shell.cardPanelState.viewportForDiagnostics)), "newest_frame": .string(String(describing: shell.cardPanelState.newestMessageFrameForDiagnostics)), "panel": .bool(shell.cardPanelState.isVisible), "mounted": .bool(shell.isConversationMounted),
            "phase": runtime.assistantActivity.map { .string(String(describing: $0.phase)) } ?? .null,
            "can_input": .bool(controller.canAcceptInput), "sessions": .number(Double(runtime.sessions.count)),
            "confirmation": shell.managed.confirmation.map { .string(String(describing: $0)) } ?? .null,
            "folder": .string(shell.managed.config.folder), "welcome_shown": .bool(settings.hasShownWelcome),
            "pane": controller.record?.pane.map { .string($0.id) } ?? .null,
            "pane_pid": controller.record?.pane.map { .number(Double($0.pid)) } ?? .null,
            "pane_start": controller.record?.pane.map { .number(Double($0.startTime)) } ?? .null,
            "native_id": controller.record?.conversation?.nativeID.map(JSONValue.string) ?? .null,
            "nonce": controller.record?.conversation.map { .string($0.nonce) } ?? .null,
            "deliveries": .array(runtime.userMessageDeliveries.map { ["id": .string($0.id), "state": .string(String(describing: $0.state))] }),
            "notices": .array(cards.notices.map { .string($0.summary) }),
            "cards": .array(cards.cards.map { card in
                ["id": .string(card.id), "title": card.title.map(JSONValue.string) ?? .null, "body": .string(card.body),
                 "status": .string(card.status.rawValue), "kind": .string(card.kind.rawValue), "seen": .bool(cards.seenIDs.contains(card.id)),
                 "revealed": .bool(cards.revealedIDs.contains(card.id)), "revealing": .bool(shell.conversation.revealer(cardID: card.id)?.isRevealing == true),
                 "skipped": .bool(card.response?.skipped == true), "options": .array(card.options.map { ["id": .string($0.id), "label": .string($0.label)] })]
            })]
    }
    func record(_ trigger: String? = nil) throws -> [String: JSONValue] {
        var value = state()
        let encoder = ZeusJSON.encoder(); encoder.outputFormatting = [.sortedKeys]
        let core = try encoder.encode(JSONValue.object(value))
        if previous != core || trigger != nil {
            previous = core; value["host_pid"] = .number(Double(ProcessInfo.processInfo.processIdentifier)); value["t"] = .number(Date().timeIntervalSince(began)); value["trigger"] = trigger.map(JSONValue.string) ?? .null
            var data = try encoder.encode(JSONValue.object(value)); data.append(10); try timeline.write(contentsOf: data)
        }
        value["t"] = .number(Date().timeIntervalSince(began)); return value
    }
    func nodes(_ window: NSWindow?) -> [NSObject] {
        guard let root = window?.contentView else { return [] }
        var seen: Set<ObjectIdentifier> = []
        func walk(_ object: Any) -> [NSObject] {
            guard let node = object as? NSObject, seen.insert(ObjectIdentifier(node)).inserted else { return [] }
            func children(_ name: String, _ argument: String? = nil) -> [Any] {
                let selector = NSSelectorFromString(name)
                guard node.responds(to: selector) else { return [] }
                return node.perform(selector, with: argument)?.takeUnretainedValue() as? [Any] ?? []
            }
            return [node] + (children("accessibilityChildren") + children("accessibilityAttributeValue:", "AXChildren")
                + children("accessibilityAttributeValue:", "AXContents") + ((node as? NSView)?.subviews ?? [])).flatMap(walk)
        }
        return walk(root)
    }
    func axString(_ node: NSObject, _ attribute: String) -> String? {
        let legacy = NSSelectorFromString("accessibilityAttributeValue:")
        let candidates = attribute == "accessibilityLabel" ? ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"] : [attribute]
        let names = ["accessibilityRole": "AXRole", "accessibilityLabel": "AXDescription", "accessibilityTitle": "AXTitle", "accessibilityValue": "AXValue"]
        for candidate in candidates {
            let modern = NSSelectorFromString(candidate)
            if node.responds(to: modern), let value = node.perform(modern)?.takeUnretainedValue() as? String, !value.isEmpty { return value }
            if let name = names[candidate], node.responds(to: legacy), let value = node.perform(legacy, with: name)?.takeUnretainedValue() as? String, !value.isEmpty { return value }
        }
        return nil
    }
    func ax(_ window: NSWindow?) -> [JSONValue] {
        nodes(window).compactMap { node in
            let role = axString(node, "accessibilityRole") ?? ""
            let label = axString(node, "accessibilityLabel") ?? ""
            guard !role.isEmpty else { return nil }
            return ["role": .string(role), "label": .string(label)]
        }
    }
    func press(_ label: String, settings: Bool) async throws {
        let window = settings ? NSApp.windows.first { $0.title == "Zeus Settings" } : conversationWindow
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
        }
        var positions: [String] = []
        for _ in 0..<14 {
            window?.contentView?.layoutSubtreeIfNeeded()
            if let node = nodes(window).first(where: { axString($0, "accessibilityLabel") == label && axString($0, "accessibilityRole") == "AXButton" }),
               (node as AnyObject).accessibilityPerformPress?() == true { return }
            guard settings, let root = window?.contentView,
                  let scroll = scrollViews(root).first(where: { $0.bounds.height > 200 && $0.bounds.width > 300 }),
                  let document = scroll.documentView else { break }
            let maxY = max(0, document.bounds.height - scroll.contentView.bounds.height)
            let current = scroll.contentView.bounds.origin.y
            positions.append("\(type(of: scroll)): y=\(current) max=\(maxY) doc=\(document.bounds.height)")
            scroll.contentView.scroll(to: CGPoint(x: 0, y: current + 220 >= maxY ? (current >= maxY - 1 ? 0 : maxY) : current + 220))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ManagedSessionError.command("OB1 missing native action: " + label + "; scroll=" + positions.joined(separator: ",") + "; labels=" + nodes(window).compactMap { axString($0, "accessibilityLabel") }.joined(separator: " | "))
    }
    func command(_ value: JSONValue) async throws -> [String: JSONValue] {
        guard case .string(let name) = value["command"] else { throw ManagedSessionError.invalidState }
        var result: [String: JSONValue] = ["ok": true]
        switch name {
        case "state": break
        case "settings": shell.showSettings(tab: .agent)
        case "talk": shell.showTalkPanel()
        case "press":
            guard case .string(let label) = value["label"] else { throw ManagedSessionError.invalidState }
            try await press(label, settings: value["settings"] == true)
        case "compose":
            guard case .string(let text) = value["text"] else { throw ManagedSessionError.invalidState }
            shell.showTalkPanel(); NSApp.activate(); conversationWindow?.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(150))
            guard let editor = conversationWindow?.firstResponder as? NSTextView else { throw ManagedSessionError.command("OB1 composer not focused") }
            editor.selectAll(nil); editor.insertText(text, replacementRange: editor.selectedRange())
            try await Task.sleep(for: .milliseconds(100))
            guard shell.conversation.draft == text else { throw ManagedSessionError.command("OB1 native editor did not update draft") }
            try await press("Send", settings: false)
            result["input"] = "native NSTextView + AX Send"
        case "render":
            let window = value["settings"] == true ? NSApp.windows.first { $0.title == "Zeus Settings" } : conversationWindow
            guard let host = window?.contentView,
                  let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw ManagedSessionError.invalidState }
            host.cacheDisplay(in: host.bounds, to: image)
            guard let rendered = image.representation(using: .png, properties: [:]) else { throw ManagedSessionError.invalidState }
            try rendered.write(to: root.appendingPathComponent(value["settings"] == true ? "settings.png" : "conversation.png"))
        case "ax":
            result["nodes"] = .array(ax(value["settings"] == true ? NSApp.windows.first { $0.title == "Zeus Settings" } : conversationWindow))
        case "snapshot":
            guard let pane = controller.record?.pane, let hosting = controller.hosting else { throw ManagedSessionError.invalidState }
            let snapshot = try await hosting.capture(pane, owner: controller.record?.owner ?? "")
            result["screen"] = .string(snapshot.plainLines.joined(separator: "\n"))
            result["classification"] = .string(String(describing: ManagedPaneClassifier.classify(snapshot, agent: .claude)))
        case "off": shell.managed.chooseManaged(false)
        default: throw ManagedSessionError.command("OB1 unknown command")
        }
        result["state"] = .object(try record(name == "state" ? nil : name)); return result
    }
    func stop() {
        runtime.stop(); shell.stop()
        for window in NSApp.windows { window.orderOut(nil) }
        try? timeline.close()
    }
}
@main private struct OB1RuntimeHost {
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let namesSelector = NSSelectorFromString("accessibilityAttributeNames")
        if app.responds(to: namesSelector), let names = app.perform(namesSelector)?.takeUnretainedValue() as? [String],
           names.contains("AXEnhancedUserInterface") {
            let setter = NSSelectorFromString("accessibilitySetValue:forAttribute:")
            if app.responds(to: setter) { app.perform(setter, with: NSNumber(value: true), with: "AXEnhancedUserInterface") }
        }
        Task { @MainActor in
            do {
                guard CommandLine.arguments.count == 5 else { throw ManagedSessionError.invalidState }
                _ = ZeusFonts.registerBundled()
                let context = try OB1Context(root: URL(fileURLWithPath: CommandLine.arguments[1]), bridge: URL(fileURLWithPath: CommandLine.arguments[2]),
                    claude: URL(fileURLWithPath: CommandLine.arguments[3]), tmux: URL(fileURLWithPath: CommandLine.arguments[4]))
                let sampling = Task { @MainActor in
                    while !Task.isCancelled { _ = try? context.record(); try? await Task.sleep(for: .milliseconds(50)) }
                }
                try write(["ready": true, "state": .object(try context.record("launch"))])
                await Task.detached {
                    var line = Data()
                    while let byte = try? FileHandle.standardInput.read(upToCount: 1), !byte.isEmpty {
                        if byte[0] == 10 {
                            let data = line
                            await Task { @MainActor in
                                do { try write(try await context.command(ZeusJSON.decoder().decode(JSONValue.self, from: data))) }
                                catch { try? write(["ok": false, "error": .string(error.localizedDescription)]) }
                            }.value
                            line.removeAll(keepingCapacity: true)
                        } else { line.append(byte) }
                    }
                }.value
                sampling.cancel(); context.stop(); app.terminate(nil)
            } catch { try? write(["ready": false, "error": .string(error.localizedDescription)]); app.terminate(nil) }
        }
        app.run()
    }
    private static func write(_ value: [String: JSONValue]) throws {
        var data = try ZeusJSON.encoder().encode(JSONValue.object(value)); data.append(10); try FileHandle.standardOutput.write(contentsOf: data)
    }
}
#endif
