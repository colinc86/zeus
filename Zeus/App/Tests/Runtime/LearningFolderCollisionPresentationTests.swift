import AppKit
import SwiftUI
import Testing
import ZeusDesign
@testable import Zeus

@MainActor struct LearningFolderCollisionPresentationTests {
    @Test func settingsExposesTheActionableCollisionMessage() async throws {
        let provider = LF1FolderFake()
        let message = try #require(LearningFolderWriter.collisionMessage(["Zeus/README.md"]))
        provider.lastWriteError = message
        let model = LearningFolderModel(provider: provider)
        let host = TestHostingView(rootView: LearningFolderView(model: model, managed: false)
            .frame(width: 680, height: 400, alignment: .topLeading)
            .environment(\.accessibilityEnabled, true).environment(\.zeusFontChoice, .system))
        let window = NSPanel(contentRect: .init(x: -20000, y: -20000, width: 680, height: 400),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.ignoresMouseEvents = true
        window.contentView = host; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        var seen: Set<ObjectIdentifier> = []
        func strings(_ value: Any) -> [String] {
            guard let node = value as? NSObject, seen.insert(ObjectIdentifier(node)).inserted else { return [] }
            let labels = ["accessibilityLabel", "accessibilityValue", "accessibilityTitle"].compactMap { name -> String? in
                let selector = NSSelectorFromString(name)
                return node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() as? String : nil
            }
            let selector = NSSelectorFromString("accessibilityChildren")
            let children = node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() as? [Any] ?? [] : []
            return labels + (children + ((node as? NSView)?.subviews ?? [])).flatMap(strings)
        }
        #expect(strings(host).contains(message))
    }
}
