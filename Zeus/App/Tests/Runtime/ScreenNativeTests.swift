import AppKit
import Foundation
import FoundationModels
import ImageIO
import Testing
@testable import Zeus

/// Opt-in only. Captures ONLY windows created by this fixture in its own process; never a user window/display.
@Suite(.serialized) @MainActor struct ScreenNativeTests {
    @Test func syntheticOnDeviceDescription() async throws {
        guard ProcessInfo.processInfo.environment["ZEUS_TEST_LM2B_MODEL"] == "1" else { return }
        guard case .available = SystemLanguageModel.default.availability else {
            print("SKIP LM2-B native description: Apple Intelligence is unavailable; fallback remains tested."); return
        }
        let result = await OnDeviceFrameDescriber.shared.generate(app: "Editor", document: "Synthetic.swift", text: "Editing a synthetic Swift test. All tests passed.")
        let description = try #require(result, "Native model declined/timed out on a synthetic description")
        #expect(!description.activity.isEmpty)
        let data = try JSONEncoder().encode(description)
        #expect(try JSONDecoder().decode(FrameDescription.self, from: data) == description)
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("TestFixtures/live/lm2b")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try data.write(to: output.appendingPathComponent("synthetic-model-description.json"))
    }
    @Test func ownedWindowCaptureCoverAndVideoCallRefusal() async throws {
        guard ProcessInfo.processInfo.environment["ZEUS_TEST_LM2B_SCREEN"] == "1" else {
            return // The normal suite never changes focus, requests permission or reads the screen.
        }
        guard let fixtureHome = ProcessInfo.processInfo.environment["ZEUS_LM2B_HOME"],
              NSHomeDirectory() == fixtureHome else {
            Issue.record("LM2-B native gate incomplete: runner did not inherit disposable HOME; no pixels captured."); return
        }
        let permission = CGPreflightScreenCaptureAccess()
        guard permission else {
            Issue.record("LM2-B native gate incomplete: Screen Recording not granted to this dev build; no pixels captured.")
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lm2b-native_" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let oldPolicy = NSApp.activationPolicy(); NSApp.setActivationPolicy(.regular)
        defer { NSApp.setActivationPolicy(oldPolicy) }
        let window = NSWindow(contentRect: NSRect(x: 120, y: 160, width: 1000, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let journal = EncryptedJournalStore(root: root, keyProvider: FixtureJournalKey())
        let redactor = LocalRedactor(useOnDeviceModel: false)
        let source = WindowScreenCapture()
        var proof: [[String: String]] = []
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("TestFixtures/live/lm2b")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for kind in ["Terminal", "Xcode", "Safari bank fixture"] {
            window.title = "Zeus synthetic screen fixture · " + kind
            let image = try ScreenTestImages.draw(bank: kind.hasPrefix("Safari"))
            let view = NSImageView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
            view.image = NSImage(cgImage: image, size: .zero); view.imageScaling = .scaleAxesIndependently
            window.contentView = view; window.makeKeyAndOrderFront(nil); NSApp.activate()
            try await Task.sleep(for: .milliseconds(800))
            let context = ScreenContext(bundleID: Bundle.main.bundleIdentifier ?? "com.colinc86.Zeus", appName: kind,
                windowTitle: window.title, windowID: UInt32(window.windowNumber), processID: ProcessInfo.processInfo.processIdentifier)
            let start = ContinuousClock.now
            let captured = try await source.capture(context)
            let elapsed = start.duration(to: .now)
            let covered = try await FrameRedactor(redactor: redactor).redact(captured, context: context)
            let description = await FrameDescriber(redactor: redactor, model: ScreenNativeNoModel()).describe(covered)
            #expect(covered.frame.value.width <= 1280); #expect(description.value.details["descriptionEngine"] == "naturalLanguage")
            let name = kind.hasPrefix("Safari") ? "bank" : kind.lowercased()
            try covered.frame.value.heic.write(to: output.appendingPathComponent(name + ".heic"))
            let imageSource = try #require(CGImageSourceCreateWithData(covered.frame.value.heic as CFData, nil))
            let encoded = try #require(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
            let ocr = try FrameRedactor.textLines(encoded).map(\.0).joined(separator: "\n")
            if name == "bank" {
                for secret in ["4401", "2233", "9876", "example.person", "123456789", "4242"] { #expect(!ocr.contains(secret)) }
            }
            proof.append(["fixture": kind, "capture": "production single-window ScreenCaptureKit; fixture-owned window/PID", "captureDuration": String(describing: elapsed), "coveredBoxes": "\(covered.frame.value.boxes.count)"])
            var blocked = context; blocked.cameraInUse = true
            var policy = ScreenPolicy(); policy.enabled = true
            let refused = ScreenObserver(journal: journal, redactor: redactor, policy: { policy }, context: { blocked })
            refused.start(); refused.captureNow(); #expect(refused.pause == .camera); refused.stop()
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(proof).write(to: output.appendingPathComponent("owned-window-proof.json"))
    }
}
private struct ScreenNativeNoModel: FrameDescriptionGenerating {
    func generate(app: String, document: String, text: String) async -> FrameDescription? { nil }
}
