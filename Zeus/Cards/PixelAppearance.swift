import SwiftUI
import ZeusDesign

/// Fades chrome in while snapping each animated offset to the same grid as its frame.
struct PixelAppearance: ViewModifier, Animatable {
    nonisolated var progress: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }
    func body(content: Content) -> some View {
        content.opacity(progress)
            .offset(y: reduceMotion ? 0 : ((1 - progress) * 3).rounded() * ZeusTheme.pixel)
    }
}
