import Foundation
import ZeusProtocol

/// Local fixtures exercise the same card store as agent tool calls.
enum DemoCardKind: String, CaseIterable, Identifiable {
    case message = "Message"
    case longMessage = "Message · long"
    case options = "Question · options"
    case text = "Question · text"
    case content = "Content · attachments"
    case progress = "Progress"
    var id: String { rawValue }

    func make(now: Date = Date()) -> Card {
        switch self {
        case .message:
            return Card(kind: .message, title: "Hello from Zeus", body: "Your assistant is ready. Type below whenever you want to talk.",
                        createdAt: now, updatedAt: now)
        case .longMessage:
            return Card(kind: .message, title: "Read from the top", body: Self.longMessageBody, createdAt: now, updatedAt: now)
        case .options:
            return Card(kind: .question, title: "Tomorrow’s presentation", body: "Your talk is tomorrow at **10:00**. Have you started?",
                        options: [CardOption(id: "yes", label: "Yes", style: .primary),
                                  CardOption(id: "no", label: "No"), CardOption(id: "later", label: "Remind me later")],
                        input: InputSpec(placeholder: "Add a note…"), priority: .high,
                        createdAt: now, updatedAt: now)
        case .text:
            return Card(kind: .question, title: "What should I focus on?", body: "Tell me about your next task. You can write **multiple lines**.",
                        input: InputSpec(placeholder: "What needs doing?", multiline: true),
                        createdAt: now, updatedAt: now)
        case .content:
            return Card(kind: .content, title: "Your work products", body: "Here are some example attachments:\n\n**Open** a file or link, or **Reveal** a local item in Finder.",
                        options: [CardOption(id: "good", label: "Looks good", style: .primary),
                                  CardOption(id: "revise", label: "Revise")],
                        attachments: [Attachment(kind: .file, label: "README", target: sourceRoot.appendingPathComponent("README.md").path),
                                      Attachment(kind: .folder, label: "Project folder", target: sourceRoot.path),
                                      Attachment(kind: .url, label: "Apple Developer", target: "https://developer.apple.com")],
                        createdAt: now, updatedAt: now)
        case .progress:
            return Card(kind: .progress, title: "Building your outline", body: "Organizing your notes into a first draft.", progress: 0.45,
                        mood: .working, createdAt: now, updatedAt: now)
        }
    }

    static let longMessageBody = (1...12).map {
        "**Part \($0)**\nThis is a long response for checking the conversation's scroll behavior. New text follows into view until this message's top reaches the viewport top. You can then read downward with the arrow keys or Page Down. Scrolling up to history keeps your place when another message arrives."
    }.joined(separator: "\n\n")

    private var sourceRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
}
