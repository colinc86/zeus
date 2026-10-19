import Foundation
import ZeusProtocol

enum MenuPresentation {
    /// Hide items, in the menu bar and the avatar's context menu alike (title case, D3-11).
    static let hideForHour = "Hide for 1 Hour"
    static let hideUntilTomorrow = "Hide Until Tomorrow"

    /// "Hidden until 2:30 PM" today, "Hidden until tomorrow, 8:00 AM", else "Hidden until Oct 19, 8:00 AM" (FX25).
    static func hiddenUntilLine(_ until: Date, now: Date, calendar: Calendar = .current) -> String {
        let time = until.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(until, inSameDayAs: now) { return "Hidden until \(time)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(until, inSameDayAs: tomorrow) {
            return "Hidden until tomorrow, \(time)"
        }
        return "Hidden until \(until.formatted(date: .abbreviated, time: .shortened))"
    }

    static func status(state: AvatarState, unread: Int, activity: AssistantActivity?, sessionLabel: String? = nil) -> String {
        if unread > 0 { return "\(unread) new \(unread == 1 ? "message" : "messages")" }
        if let activity {
            if let detail = activity.detail { return [sessionLabel, detail].compactMap { $0 }.joined(separator: " · ") }
            return "\(sessionLabel ?? activity.agentName) is \(activity.phase == .sent ? "receiving your message" : activity.phase == .thinking ? "thinking" : "working")…"
        }
        switch state {
        case .waiting: return "Waiting for your answer"
        case .sleeping: return "Quiet for now"
        case .thinking, .working: return "Your assistant is working…"
        case .happy: return "Task complete"
        case .talking: return "A message from your assistant"
        case .idle, .alert: return "Ready to talk"
        }
    }
}
