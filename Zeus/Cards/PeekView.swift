import AppKit
import SwiftUI
import Observation
import ZeusDesign

@MainActor @Observable
final class PeekPanelState {
    var tail = ZeusDialogTail(edge: .bottom, offset: 140)
    var layout = PeekLayout()
}

struct PeekView: View {
    let model: PeekModel
    let panel: PeekPanelState
    let settings: AppSettings
    let activity: SurfaceActivity
    let open: (PeekModel.OpenAction) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // T1: the selected theme reaches every view below through \.zeusTheme (and so \.zeusPalette).
    var body: some View { rootBody.environment(\.zeusTheme, settings.currentTheme) }

    private var rootBody: some View {
        return Group {
            if model.isVisible, let card = model.card {
                PeekContent(card: card, layout: panel.layout, moreCount: model.moreCount, error: model.answerError,
                            answeredOptionID: model.answeredOptionID, tail: panel.tail,
                            reveal: !model.isTyping || reduceMotion || !settings.typewriterEnabled ? .full : .typing(start: model.startedAt),
                            open: open, answer: { _ = model.answer(optionID: $0) }, close: { model.close(markSeen: true) })
                    .background { Color.clear.contentShape(Rectangle()).onTapGesture { open(.message) } }
                    .onHover { model.setHovering($0) }
                    .transition(.zeusPeek(reduceMotion: reduceMotion, edge: panel.tail.edge))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .environment(\.zeusAnimationsActive, activity.peek)
        .environment(\.zeusFontChoice, settings.fontChoice)
        .environment(\.openURL, OpenURLAction { _ in open(.message); return .handled })
        .animation(.easeOut(duration: model.isVisible ? ZeusPeekTiming.enterDuration : ZeusPeekTiming.exitDuration), value: model.isVisible)
    }
    static func errorComesFirst(edge: ZeusDialogTail.Edge) -> Bool { edge == .bottom }

}

/// Clicks work immediately without giving the peek panel keyboard focus.
@MainActor
final class PeekHostingView: NSHostingView<PeekView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
