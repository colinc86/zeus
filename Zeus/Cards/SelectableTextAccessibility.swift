import SwiftUI

extension View {
    /// Labels selectable text for VoiceOver without crashing it.
    /// A label set directly on `.textSelection(.enabled)` text recurses forever on macOS 26 once an assistive app
    /// turns on enhanced accessibility: the text's backing view asks SwiftUI for its label, which asks the view again.
    /// The label goes on a wrapping element instead. Use `.contain` where VoiceOver must still reach links inside.
    func selectableTextAccessibilityLabel(_ label: String, children: AccessibilityChildBehavior = .ignore) -> some View {
        accessibilityElement(children: children).accessibilityLabel(label)
    }
}
