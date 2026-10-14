import SwiftUI
import ZeusDesign

struct MessageBodyView: View {
    let markdown: AttributedString
    let active: Bool
    let enabled: Bool
    let soundEnabled: Bool
    let reveal: TypewriterModel?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Environment(\.zeusAnimationsActive) private var animationsActive

    private struct Request: Equatable {
        var text: String
        var animate: Bool
        var sound: Bool
    }
    private var request: Request {
        Request(text: String(markdown.characters), animate: animationsActive && active && enabled && !reduceMotion && reveal != nil,
                sound: animationsActive && active && enabled && soundEnabled && !reduceMotion && reveal != nil)
    }
    private var visible: AttributedString {
        guard request.animate, let reveal, reveal.text == String(markdown.characters) else { return markdown }
        let count = min(reveal.visibleCount, markdown.characters.count)
        let end = markdown.characters.index(markdown.startIndex, offsetBy: count)
        return AttributedString(markdown[markdown.startIndex..<end])
    }
    var accessibilityText: String { ZeusMarkdown.spokenText(markdown) }
    var body: some View {
        Text(visible).zeusFont(.body).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(accessibilityText)
            // Simultaneous, not exclusive: a click on a link inside the text must still open it (user report, 2026-10-14).
            .simultaneousGesture(TapGesture().onEnded { reveal?.finish() })
            .onDisappear { reveal?.finish() }
            .task(id: request) {
                let request = request
                guard let reveal else { return }
                guard reveal.text == request.text else { reveal.finish(); return }
                guard active else { if reveal.wasDisplayed { reveal.finish() }; return }
                reveal.markDisplayed()
                guard request.animate else { reveal.finish(); return }
                while request.animate && reveal.isRevealing {
                    do { try await Task.sleep(for: .milliseconds(25)) } catch { return }
                    if reveal.tick() && request.sound { RetroBlip.shared.play() }
                }
            }
    }
}
