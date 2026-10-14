import Foundation
import Observation

/// Only presentation clocks stop; the runtime and card store remain live while suspended.
@MainActor @Observable
final class SurfaceActivity {
    private(set) var avatar = false
    private(set) var conversation = false
    private(set) var peek = false
    private(set) var settings = false

    func update(suspended: Bool, avatar: Bool, conversation: Bool, peek: Bool, settings: Bool) {
        let next = (!suspended && avatar, !suspended && conversation, !suspended && peek, !suspended && settings)
        if self.avatar != next.0 { self.avatar = next.0 }
        if self.conversation != next.1 { self.conversation = next.1 }
        if self.peek != next.2 { self.peek = next.2 }
        if self.settings != next.3 { self.settings = next.3 }
    }
}
