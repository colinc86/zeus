import Foundation

/// Pure idle-fade reducer. The shell sleeps until nextDeadline; tests supply time directly.
struct AvatarGhostState {
    struct Configuration: Equatable {
        var enabled = false
        var opacity = 0.3
        var delay: TimeInterval = 30
        static func opacity(_ value: Double) -> Double { value.isFinite ? min(0.9, max(0.1, value)) : 0.3 }
        static func delay(_ value: Double) -> Double { value.isFinite ? min(600, max(5, value)) : 30 }
    }
    struct Inputs: Equatable {
        var visible = true
        var panelOpen = false
        var peekVisible = false
        var hovered = false
        var questionWaiting = false
        var assistantBusy = false
        var holdsVisible: Bool { !visible || panelOpen || peekVisible || hovered || questionWaiting || assistantBusy }
    }
    private(set) var alpha = 1.0
    private(set) var nextDeadline: Date?
    private var lastInteraction: Date?
    private var previousInputs: Inputs?
    private var previousConfiguration: Configuration?

    /// Every interaction and release of an inhibition starts a full new delay.
    /// Hidden/suspended avatars have no fade deadline and return at full opacity.
    mutating func update(at now: Date, configuration: Configuration, inputs: Inputs, interaction: Bool = false) {
        if lastInteraction == nil || interaction || previousConfiguration != configuration
            || previousInputs?.holdsVisible == true || inputs.holdsVisible || lastInteraction.map({ now < $0 }) == true {
            lastInteraction = now
        }
        previousInputs = inputs; previousConfiguration = configuration
        guard configuration.enabled, !inputs.holdsVisible else { alpha = 1; nextDeadline = nil; return }
        let deadline = (lastInteraction ?? now).addingTimeInterval(Configuration.delay(configuration.delay))
        alpha = now >= deadline ? Configuration.opacity(configuration.opacity) : 1
        nextDeadline = now < deadline ? deadline : nil
    }
    static func animationDuration(reduceMotion: Bool) -> TimeInterval { reduceMotion ? 0 : 0.2 }
}
