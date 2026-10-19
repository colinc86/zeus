import AppKit
import SwiftUI
import Testing
import ZeusDesign
@testable import Zeus

/// Public accessibility children plus view subviews, visited once, bounded. Never the private AX attribute paths.
@MainActor private func ux5Nodes(_ root: Any) -> [NSObject] {
    var visited: Set<ObjectIdentifier> = []
    func walk(_ value: Any, depth: Int) -> [NSObject] {
        guard depth < 60, let node = value as? NSObject, visited.insert(ObjectIdentifier(node)).inserted else { return [] }
        let children = ((node as AnyObject).accessibilityChildren?() ?? nil) ?? []
        return [node] + (children + ((node as? NSView)?.subviews ?? [])).flatMap { walk($0, depth: depth + 1) }
    }
    return walk(root, depth: 0)
}
@MainActor private func ux5Text(_ node: NSObject) -> String {
    for name in ["accessibilityLabel", "accessibilityValue", "accessibilityTitle"] {
        let selector = NSSelectorFromString(name)
        if node.responds(to: selector), let value = node.perform(selector)?.takeUnretainedValue() as? String, !value.isEmpty { return value }
    }
    return ""
}

/// UX5: Settings say everything Zeus sends (PRIVACY.md §2.5, §4.2 empty states; AGENT_LEARNING.md §8.4).
@Suite(.serialized) @MainActor struct UX5WhatZeusSendsTests {
    private func mount<V: View>(_ view: V, width: CGFloat = 740, height: CGFloat = 700) async throws -> (TestHostingView, NSWindow) {
        ZeusFonts.registerBundled()
        let host = TestHostingView(rootView: view.frame(width: width, height: height, alignment: .topLeading)
            .environment(\.accessibilityEnabled, true).environment(\.zeusFontChoice, .system)
            .buttonStyle(ZeusButtonStyle(.secondary, size: .small)).background(ZeusPalette.for(.light).panel))
        let window = NSPanel(contentRect: .init(x: -20000, y: -20000, width: width, height: height), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.ignoresMouseEvents = true
        window.contentView = host; window.orderFront(nil)
        for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        return (host, window)
    }
    private func freshSettings() -> LearnSettings {
        let suite = TestDefaults.suite("ux5")
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return LearnSettings(defaults: defaults)
    }

    @Test func ledgerEmptyCaptionNamesTheBriefWhenLearningIsOff() {
        let viewer = JournalViewerModel(journal: LM2JournalFake()); viewer.sentOnly = true
        viewer.learningEnabled = { false }; viewer.briefEnabled = { false }
        #expect(viewer.emptyCaption == JournalViewerModel.emptyLearningOff)
        viewer.briefEnabled = { true }
        #expect(viewer.emptyCaption == JournalViewerModel.emptyLearningOffBriefOn)
        #expect(viewer.emptyCaption.contains("Settings › Assistant"))
        viewer.learningEnabled = { true }
        #expect(viewer.emptyCaption == JournalViewerModel.emptyNothingPrepared)
        #expect(viewer.emptyCaption.contains("evening reflection"))
    }

    @Test func stateSentencesFollowTheSwitches() {
        #expect(WhatZeusSendsView.summaryState(activityOn: true) == "Sent while Apps and timing is on.")
        #expect(WhatZeusSendsView.summaryState(activityOn: false) == "Not sent: Apps and timing is off.")
        #expect(WhatZeusSendsView.reflectionState(anyLevelOn: true) == "Sent while any level is on.")
        #expect(WhatZeusSendsView.reflectionState(anyLevelOn: false) == "Not sent: every level is off.")
        #expect(WhatZeusSendsView.briefState(true) == "On." && WhatZeusSendsView.briefState(false) == "Off.")
        #expect(WhatZeusSendsView.briefCaption.contains("even when Learn from me is off"))
    }

    @Test func rowsPointAtTheirSettingsAndNotesFollowLevelOne() async throws {
        let settings = freshSettings()
        var assistant = 0, rules = 0
        let (host, window) = try await mount(WhatZeusSendsView(settings: settings, activityOn: false, anyLevelOn: true, briefOn: true,
                                                               openAssistant: { assistant += 1 }, openRules: { rules += 1 }))
        defer { window.contentView = nil; window.close() }
        let nodes = ux5Nodes(host)
        let brief = try #require(nodes.first { ux5Text($0) == "Assistant Settings, morning brief" })
        #expect((brief as AnyObject).accessibilityPerformPress?() == true && assistant == 1)
        let open = try #require(nodes.first { ux5Text($0) == "Open Rules" })
        #expect((open as AnyObject).accessibilityPerformPress?() == true && rules == 1)
        let note = try #require(nodes.first { ux5Text($0) == MomentKind.allCases[0].title })
        #expect((note as AnyObject).isAccessibilityEnabled?() == false)
        #expect(nodes.contains { ux5Text($0).hasPrefix("Morning summary. ") && ux5Text($0).hasSuffix("Not sent: Apps and timing is off.") })
        #expect(nodes.contains { ux5Text($0).hasPrefix("Evening reflection. ") && ux5Text($0).hasSuffix("Sent while any level is on.") })
        #expect(nodes.contains { ux5Text($0).hasPrefix("Morning brief request. ") && ux5Text($0).hasSuffix("On.") })
    }

    @Test func standaloneRowsHaveNoBriefButton() async throws {
        let settings = freshSettings()
        let (host, window) = try await mount(WhatZeusSendsView(settings: settings, activityOn: true, anyLevelOn: true, briefOn: nil))
        defer { window.contentView = nil; window.close() }
        let nodes = ux5Nodes(host)
        #expect(!nodes.contains { ux5Text($0) == "Assistant Settings, morning brief" })
        #expect(!nodes.contains { ux5Text($0) == "Open Rules" })
        let note = try #require(nodes.first { ux5Text($0) == MomentKind.allCases[0].title })
        #expect((note as AnyObject).isAccessibilityEnabled?() != false)
    }

    @Test func folderRowSaysWhyChooseIsDisabled() async throws {
        let (host, window) = try await mount(LearningFolderView(model: LearningFolderModel(provider: nil), managed: false))
        defer { window.contentView = nil; window.close() }
        let nodes = ux5Nodes(host)
        #expect(nodes.contains { ux5Text($0) == LearningFolderView.noJournalCaption })
        let choose = try #require(nodes.first { ux5Text($0) == "Choose learnings folder" })
        #expect((choose as AnyObject).isAccessibilityEnabled?() == false)
        let (managedHost, managedWindow) = try await mount(LearningFolderView(model: LearningFolderModel(provider: nil), managed: true))
        defer { managedWindow.contentView = nil; managedWindow.close() }
        #expect(!ux5Nodes(managedHost).contains { ux5Text($0) == LearningFolderView.noJournalCaption })
    }

    @Test func briefScheduleChoicesBothCarryADetailLine() async throws {
        let suite = TestDefaults.suite("ux5-brief")
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defer { defaults.removePersistentDomain(forName: suite) }
        let brief = MorningBriefSettings(defaults: defaults); brief.enabled = true
        let (host, window) = try await mount(MorningBriefSettingsView(settings: brief, managed: true))
        defer { window.contentView = nil; window.close() }
        let labels = ux5Nodes(host).map(ux5Text)
        #expect(labels.contains("After my first activity. " + MorningBriefSettingsView.firstActivityDetail))
        #expect(labels.contains("At a fixed time. " + MorningBriefSettingsView.fixedTimeDetail))
    }
}
