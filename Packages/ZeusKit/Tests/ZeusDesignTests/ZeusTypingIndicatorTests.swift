import Foundation
import SwiftUI
import Testing
@testable import ZeusDesign

private typealias Typing = ZeusTypingIndicator

@Test func typingDotsHopInTurnThenRest() {
    let base = Typing.epoch
    let frames = (0..<8).map { Typing.dots(phase: .thinking, at: base.addingTimeInterval(Double($0) * 0.2 + 0.01)) }
    let lifted = frames.map { $0.firstIndex(where: \.lifted) }
    #expect(lifted == [0, 1, 2, nil, 0, 1, 2, nil])
    #expect(frames.allSatisfy { $0.count == 3 && $0.filter(\.lit).count <= 1 })
}

@Test func sentPulsesSlowlyWithoutHopping() {
    let base = Typing.epoch
    let frames = (0..<8).map { Typing.dots(phase: .sent, at: base.addingTimeInterval(Double($0) * 0.4 + 0.01)) }
    #expect(frames.allSatisfy { $0.allSatisfy { !$0.lifted } })
    #expect(frames.map { $0.firstIndex(where: \.lit) } == [0, 1, 2, nil, 0, 1, 2, nil])
}

@Test func typingClockStaysUnderSixChangesPerSecond() {
    for phase in Typing.Phase.allCases {
        #expect(1 / Typing.interval(for: phase) <= 6)
    }
    // Same frame for the whole step: no hidden display-rate dependence.
    let t = Typing.epoch.addingTimeInterval(1000.21)
    #expect(Typing.dots(phase: .working, at: t) == Typing.dots(phase: .working, at: t.addingTimeInterval(0.15)))
    // Times before the epoch still land in 0..<4.
    #expect((0..<4).contains(Typing.step(phase: .thinking, at: Date.distantPast)))
}

@Test func typingRestingFrames() {
    #expect(Typing.restingDots(phase: .thinking).allSatisfy { $0.lit && !$0.lifted })
    #expect(Typing.restingDots(phase: .sent).allSatisfy { !$0.lit && !$0.lifted })
}

@Test func typingCaption() {
    #expect(Typing.caption(phase: .thinking, detail: nil) == nil)
    #expect(Typing.caption(phase: .sent, detail: "  ") == "Sent")                        // DES-21: words, not just dim dots
    #expect(Typing.caption(phase: .sent, detail: nil, agentName: "Claude Code") == "Sent to Claude Code")
    #expect(Typing.caption(phase: .working, detail: nil) == "Working…")
    #expect(Typing.caption(phase: .working, detail: " Drafting\nmore ") == "Drafting")
    #expect(Typing.caption(phase: .thinking, detail: "Reading notes") == "Reading notes")
}

@Test func typingAccessibilityLabel() {
    #expect(Typing.accessibilityLabel(phase: .sent, agentName: "Claude", detail: nil, progress: nil) == "Sent to Claude")
    #expect(Typing.accessibilityLabel(phase: .thinking, agentName: nil, detail: nil, progress: nil) == "Assistant is thinking")
    #expect(Typing.accessibilityLabel(phase: .working, agentName: "Claude", detail: "Drafting", progress: 0.404)
            == "Claude is working, Drafting, 40 percent")
    #expect(Typing.accessibilityLabel(phase: .working, agentName: "", detail: nil, progress: .nan) == "Assistant is working")
}

@Test func thinProgressSnapsToPixels() {
    #expect(ZeusThinProgress.fillWidth(value: 0.4, width: 101) == 40)
    #expect(ZeusThinProgress.fillWidth(value: 2, width: 100) == 100)
    #expect(ZeusThinProgress.fillWidth(value: -1, width: 100) == 0)
    #expect(ZeusThinProgress.fillWidth(value: .infinity, width: 100) == 0)
    #expect(ZeusThinProgress.fillWidth(value: 0.5, width: 0) == 0)
    let w = ZeusThinProgress.fillWidth(value: 0.333, width: 157)
    #expect(w.truncatingRemainder(dividingBy: ZeusTheme.pixel) == 0)
}

@MainActor @Test func typingIndicatorRendersAndHoldsStillWhenInactive() async throws {
    ZeusFonts.registerBundled()
    func snapshot<V: View>(_ view: V, active: Bool) throws -> (Data, Int, Int) {
        let renderer = ImageRenderer(content: view.environment(\.zeusAnimationsActive, active).frame(width: 340))
        let image = try #require(renderer.cgImage)
        return (try #require(image.dataProvider?.data as Data?), image.width, image.height)
    }
    let views = [Typing(.sent), Typing(.thinking, agentName: "Claude"),
                 Typing(.working, detail: "Drafting your Q3 talk", progress: 0.4)]
    // Warm up: font registration reaches SwiftUI's font cache asynchronously, so the very first render of
    // pixel-font text (".sent" now has a caption) can differ from later ones.
    _ = try snapshot(views[2], active: false)
    try await Task.sleep(for: .milliseconds(300))
    var heights: [Int] = []
    for view in views {
        let first = try snapshot(view, active: false)
        #expect(first.1 > 0 && first.2 > 0)
        heights.append(first.2)
        try await Task.sleep(for: .milliseconds(250))   // more than one 0.2 s step
        #expect(try snapshot(view, active: false).0 == first.0)
    }
    #expect(heights[2] > heights[1])                     // the progress bar adds a line
    // Different still frames really draw differently (the hop is visible).
    let a = try snapshot(Typing(.thinking, stillFrame: Typing.epoch.addingTimeInterval(0.01)), active: false).0
    let b = try snapshot(Typing(.thinking, stillFrame: Typing.epoch.addingTimeInterval(0.21)), active: false).0
    #expect(a != b)
}

@Test func layerKeyframesMatchTheSwiftUIFrames() {
    for phase in Typing.Phase.allCases {
        for i in 0..<3 {
            let lit = TypingDotsLayer.litSteps(dot: i, phase: phase)
            let lifted = TypingDotsLayer.liftedSteps(dot: i, phase: phase)
            for step in 0..<4 {
                let t = Typing.epoch.addingTimeInterval((Double(step) + 0.5) * Typing.interval(for: phase))
                let dot = Typing.dots(phase: phase, at: t)[i]
                #expect(lit[step] == dot.lit && lifted[step] == dot.lifted)
            }
        }
    }
}

#if canImport(AppKit)
import AppKit

/// The live path: Core Animation, not a SwiftUI clock. Checks in window coordinates that the dot
/// due at this moment is the one raised and lit, so the hop goes up whatever flips AppKit applies.
@MainActor @Test func liveDotsHopUpInTheWindow() async throws {
    let host = NSHostingView(rootView: Typing(.thinking, agentName: "Claude").environment(\.zeusAnimationsActive, true)
        .frame(width: 300))
    host.frame = CGRect(x: 0, y: 0, width: 300, height: 60)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    func find(_ view: NSView) -> TypingDotsLayerView.DotsView? {
        (view as? TypingDotsLayerView.DotsView) ?? view.subviews.lazy.compactMap(find).first
    }
    let dotsView = try #require(find(host))
    dotsView.layout()
    CATransaction.flush()
    // Sample mid-step, away from a boundary.
    let interval = Typing.interval(for: .thinking)
    for _ in 0..<3 {
        let phaseInStep = Date().timeIntervalSince(Typing.epoch).truncatingRemainder(dividingBy: interval) / interval
        if phaseInStep > 0.2 && phaseInStep < 0.7 { break }
        try await Task.sleep(for: .milliseconds(70))
    }
    let step = Typing.step(phase: .thinking, at: Date())
    let dots = try #require(dotsView.layer?.sublayers)
    #expect(dots.count == 3)
    let windowY = dots.map { dot -> CGFloat in
        let p = dot.presentation() ?? dot
        return dotsView.layer!.convert(p.position, to: host.layer).y * (host.isFlipped ? -1 : 1)
    }
    let opacities = dots.map { ($0.presentation() ?? $0).opacity }
    for i in 0..<3 {
        let raised = windowY[i] > (windowY.min() ?? 0) + 0.5
        #expect(raised == (i == step), "dot \(i) at step \(step): \(windowY)")
        #expect((opacities[i] == 1) == (i == step))
    }
}
#endif
