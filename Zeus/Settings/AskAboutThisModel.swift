import Foundation
import Observation
import ZeusProtocol

/// Explicit local capture. No messaging capability is reachable here; only the composer's Send can transmit these files.
@MainActor final class AskAboutThisModel {
    private let policies: ObservationSettings
    private let privacy: LearnSettings
    private let source: any FocusCaptureSource
    private let redactor: any Redactor
    private let paused: () -> Bool
    private let captureScreen: () async -> ScreenCaptureResult?
    private var generation = UUID()
    init(policies: ObservationSettings, privacy: LearnSettings, source: any FocusCaptureSource, redactor: any Redactor,
         paused: @escaping () -> Bool = { false }, captureScreen: @escaping () async -> ScreenCaptureResult? = { nil }) {
        self.policies = policies; self.privacy = privacy; self.source = source; self.redactor = redactor
        self.paused = paused; self.captureScreen = captureScreen
    }
    func invalidate() { generation = UUID() }
    private func allowed(_ app: FocusApplication, level: Int) -> Bool {
        let policy = policies.policy(level)
        return policy.enabled && policy.consented && !paused() && !source.isSecure && !source.isLocked
            && app.bundleID != "com.colinc86.Zeus" && !app.bundleID.hasPrefix("local.zeus.")
            && source.application == app && policy.allows(bundleID: app.bundleID, name: app.name, privateApps: privacy.excludedApps)
    }
    func capture(directory: URL) async -> ContextDraftResult {
        let l2 = policies.policy(2), l3 = policies.policy(3), token = generation
        guard (l2.enabled && l2.consented) || (l3.enabled && l3.consented) else { return .init(caption: ContextDraftResult.unavailable) }
        var result = ContextDraftResult(caption: ContextDraftResult.explanation)
        guard let app = source.application, !paused(), !source.isSecure, !source.isLocked else {
            result.caption += " " + ContextDraftResult.privateCaption; return result
        }
        let requestedWindow = source.windowIdentity
        var hidden = false
        func valid(_ level: Int) -> Bool { (requestedWindow == nil || source.windowIdentity == requestedWindow) && token == generation && !Task.isCancelled && allowed(app, level: level) && policies.policy(2) == l2 && policies.policy(3) == l3 }
        do {
            // Capture pixels first, while the original app still owns focus. No panel is opened during this await.
            if l3.enabled && l3.consented {
                if valid(3), let screen = await captureScreen(), valid(3), screen.identity.bundleID == app.bundleID,
                   screen.identity.processID == app.pid, requestedWindow == nil || screen.identity == requestedWindow, let frame = screen.frame {
                    let file = try save(frame.value.heic, extension: "heic", directory: directory)
                    result.items.append(.init(attachment: .init(kind: .file, label: "Picture · " + frame.value.appName, target: file.path),
                                              kind: .picture, preview: frame.value.windowTitle))
                } else { hidden = true }
            }
            if l2.enabled && l2.consented {
                if valid(2), source.isTrusted, let captured = try await source.captureForQuestion(app), valid(2) {
                    let safe = await redactor.redact(JournalPayload(description: captured.record.title,
                        text: captured.record.text, details: ["selection": captured.selection ?? "", "address": captured.record.address ?? ""]))
                    guard valid(2) else { return discard(result) }
                    // App-only Safari records must never become a misleading Window chip.
                    if captured.record.title != "Details not kept", !safe.value.description.isEmpty {
                        result.items.append(try textItem(.window, label: safe.value.description, text: safe.value.text ?? safe.value.description, directory: directory))
                    }
                    if let selection = safe.value.details["selection"], !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        result.items.append(try textItem(.selection, label: "\(selection.split(whereSeparator: \.isWhitespace).count) words", text: selection, directory: directory))
                    }
                    if let address = safe.value.details["address"], let url = URL(string: address),
                       ["https", "http"].contains(url.scheme?.lowercased() ?? ""), let host = url.host, url.user == nil, url.password == nil,
                       !address.contains("‹") {
                        result.items.append(.init(attachment: .init(kind: .url, label: "Page · " + host, target: address), kind: .page, preview: address))
                    }
                    if captured.record.title == "Details not kept" { hidden = true }
                } else { hidden = true }
            }
        } catch { hidden = true }
        guard token == generation, !Task.isCancelled, !paused(), !source.isSecure, !source.isLocked, source.application == app, requestedWindow == nil || source.windowIdentity == requestedWindow else { return discard(result) }
        if hidden { result.caption += " " + ContextDraftResult.privateCaption }
        return result
    }
    private func textItem(_ kind: ContextDraftItem.Kind, label: String, text: String, directory: URL) throws -> ContextDraftItem {
        let file = try save(Data(text.utf8), extension: "txt", directory: directory)
        return .init(attachment: .init(kind: .file, label: kind.rawValue + " · " + label, target: file.path), kind: kind, preview: text)
    }
    private func save(_ data: Data, extension ext: String, directory: URL) throws -> URL {
        guard data.count <= AvatarDrop.maximumBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }
    private func discard(_ result: ContextDraftResult) -> ContextDraftResult {
        for item in result.items where item.attachment.kind == .file { try? FileManager.default.removeItem(atPath: item.attachment.target) }
        return .init(caption: ContextDraftResult.explanation + " " + ContextDraftResult.privateCaption)
    }
}
