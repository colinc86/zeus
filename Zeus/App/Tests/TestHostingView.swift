import AppKit
import SwiftUI
import ZeusDesign

/// Static layout/AX host by default. Opt in only when the assertion needs animation
/// (for example the peek's deterministic reveal fractions).
@MainActor final class TestHostingView: NSHostingView<AnyView> {
    private let animationsEnabled: Bool

    init<Content: View>(rootView: Content, animationsEnabled: Bool = false) {
        self.animationsEnabled = animationsEnabled
        super.init(rootView: Self.wrap(rootView, animationsEnabled: animationsEnabled))
    }

    required init(rootView: AnyView) {
        animationsEnabled = false
        super.init(rootView: Self.wrap(rootView, animationsEnabled: false))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Test hosts are constructed programmatically") }

    func setRootView<Content: View>(_ content: Content) {
        rootView = Self.wrap(content, animationsEnabled: animationsEnabled)
    }

    private static func wrap<Content: View>(_ content: Content, animationsEnabled: Bool) -> AnyView {
        AnyView(content.environment(\.zeusAnimationsActive, animationsEnabled)
            .transaction { transaction in
                if !animationsEnabled {
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
            })
    }

    override func layout() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animationsEnabled ? context.duration : 0
            context.allowsImplicitAnimation = animationsEnabled
            super.layout()
        }
    }
}
