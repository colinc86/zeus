import Intents

/// Use only publicly shared Focus status. Unknown or unauthorized status never prompts the user.
@MainActor
enum FocusStatus {
    static var isFocused: Bool? {
        let center = INFocusStatusCenter.default
        guard center.authorizationStatus == .authorized else { return nil }
        return center.focusStatus.isFocused
    }
}
