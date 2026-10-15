import AppKit
import SwiftUI
import Testing
import ZeusDesign

@MainActor private final class AnimationEnvironment {
    var active: Bool?
}
private struct AnimationEnvironmentProbe: NSViewRepresentable {
    let observed: AnimationEnvironment
    func makeNSView(context: Context) -> NSView {
        observed.active = context.environment.zeusAnimationsActive
        return NSView()
    }
    func updateNSView(_ view: NSView, context: Context) {
        observed.active = context.environment.zeusAnimationsActive
    }
}

@MainActor struct TestHostDefaultsTests {
    @Test func automaticWindowMotionIsDisabledWithoutPersistingPreferences() {
        guard ProcessInfo.processInfo.environment["ZEUS_TEST_WINDOW_ANIMATIONS"] == nil else { return }
        #expect(!UserDefaults.standard.bool(forKey: "NSAutomaticWindowAnimationsEnabled"))
        #expect((UserDefaults.standard.volatileDomain(forName: UserDefaults.registrationDomain)["NSAutomaticWindowAnimationsEnabled"] as? Bool) == false)
    }

    @Test(arguments: [false, true])
    func hostedAnimationPolicyHasAnExplicitOptIn(_ active: Bool) {
        let observed = AnimationEnvironment()
        let host = TestHostingView(rootView: AnimationEnvironmentProbe(observed: observed), animationsEnabled: active)
        host.frame = CGRect(x: 0, y: 0, width: 80, height: 40)
        host.layoutSubtreeIfNeeded()
        #expect(observed.active == active)
    }

    @Test func replacingAnErasedRootPreservesTheStaticDefault() {
        let first = AnimationEnvironment(), second = AnimationEnvironment()
        let host = TestHostingView(rootView: AnyView(AnimationEnvironmentProbe(observed: first)))
        host.frame = CGRect(x: 0, y: 0, width: 80, height: 40)
        host.layoutSubtreeIfNeeded()
        host.setRootView(AnyView(AnimationEnvironmentProbe(observed: second)))
        host.layoutSubtreeIfNeeded()
        #expect(first.active == false && second.active == false)
    }
}
