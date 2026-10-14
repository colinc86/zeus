import AppKit
import SwiftUI
import ZeusProtocol
import ZeusSprites
import ZeusDesign

struct CharacterAnimationView: View {
    let character: SpriteCharacter
    let state: AvatarState
    let scale: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Environment(\.zeusAnimationsActive) private var animationsActive
    @State private var mounted = false

    private var inputs: SpriteAnimationDriver.Inputs {
        .init(character: character, state: state, reduceMotion: reduceMotion, active: animationsActive && mounted)
    }

    var body: some View {
        PixelSpriteView(character: character, inputs: inputs)
        .frame(width: CGFloat(character.canvasSize.width * scale), height: CGFloat(character.canvasSize.height * scale))
        .accessibilityLabel("\(character.name), \(Self.spokenState(state))")
        .onAppear { mounted = true }
        .onDisappear { mounted = false }
    }
}

struct SpriteAvatarView: View {
    let settings: AppSettings
    let status: AvatarStatusModel
    let messaging: any AgentMessaging
    let artLayout: AvatarArtLayout
    let activity: SurfaceActivity

    var body: some View {
        Group {
            if let character = settings.currentCharacter {
                CharacterAnimationView(character: character, state: status.state, scale: settings.pixelScale)
            } else {
                Image(systemName: "bolt.fill").frame(width: 96, height: 112)
                    .accessibilityLabel("Character unavailable")
            }
        }
        .overlay(alignment: .topLeading) {
            if status.badgeCount > 0 {
                ZeusBadge(count: status.badgeCount)
                    .alignmentGuide(.leading) { $0[.trailing] }
                    .offset(x: artLayout.rect.badgeCorner.x, y: artLayout.rect.badgeCorner.y)
                    .accessibilityLabel("\(status.badgeCount) unread \(status.badgeCount == 1 ? "message" : "messages")")
            }
            if let issue = messaging.deliveryIssue {
                let marker = artLayout.rect.warningTopLeft
                ZeusWarningMarker()
                    .frame(width: marker.width, height: marker.height)
                    .offset(x: marker.minX, y: marker.minY)
                    .accessibilityLabel(issue.detail)
            }
        }
        .environment(\.zeusAnimationsActive, activity.avatar)
        .environment(\.zeusFontChoice, settings.fontChoice)
        .help(status.deliveryProblem ?? status.presentation.detail ?? "Click to talk; drag to move Zeus.")
    }
}

/// Handles a click versus a drag without ever making the avatar panel key.
@MainActor
final class AvatarInteractionView: NSHostingView<SpriteAvatarView> {
    var onWarning: (() -> Void)?
    var onShowDeliveryProblem: (() -> Void)?
    var hasWarning: (() -> Bool)?
    var warningFrame: (() -> CGRect)?
    var onClick: (() -> Void)?
    var contextMenu: (() -> NSMenu)?
    var onMove: ((CGPoint) -> Void)?
    var onDragEnd: (() -> Void)?
    var onInteraction: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    private var hoverArea: NSTrackingArea?
    private var startMouse = CGPoint.zero
    private var startOrigin = CGPoint.zero
    private var dragged = false

    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); hoverArea = area
        if let window {
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            onHover?(window.isVisible && bounds.contains(point))
        }
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

    override func mouseDown(with event: NSEvent) {
        onInteraction?()
        startMouse = NSEvent.mouseLocation
        startOrigin = window?.frame.origin ?? .zero
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        onInteraction?()
        let current = NSEvent.mouseLocation
        let dx = current.x - startMouse.x, dy = current.y - startMouse.y
        if !dragged && hypot(dx, dy) < 3 { return }
        dragged = true
        onMove?(CGPoint(x: startOrigin.x + dx, y: startOrigin.y + dy))
    }

    override func rightMouseDown(with event: NSEvent) {
        onInteraction?()
        if let menu = contextMenu?() { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }

    override func mouseUp(with event: NSEvent) {
        if dragged { onDragEnd?() }
        else {
            let point = convert(event.locationInWindow, from: nil)
            let marker = warningFrame?() ?? .zero
            if hasWarning?() == true && marker.contains(point) { onWarning?() } else { onClick?() }
        }
    }

    override func accessibilityLabel() -> String? {
        let name = rootView.settings.currentCharacter?.name ?? "Zeus"
        let count = rootView.status.badgeCount
        var parts = [name, "Click to talk; drag to move."]
        if count > 0 { parts.append("\(count) unread \(count == 1 ? "message" : "messages")") }
        if let issue = rootView.messaging.deliveryIssue { parts.append(issue.title); parts.append(issue.detail) }
        return parts.joined(separator: ". ")
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard rootView.messaging.deliveryIssue != nil else { return [] }
        return [NSAccessibilityCustomAction(name: "Show delivery problem", target: self,
                                            selector: #selector(accessibilityShowDeliveryProblem))]
    }

    @objc func accessibilityShowDeliveryProblem() -> Bool {
        guard rootView.messaging.deliveryIssue != nil, let onShowDeliveryProblem else { return false }
        onShowDeliveryProblem()
        return true
    }

    override func accessibilityPerformPress() -> Bool {
        onInteraction?()
        onClick?()
        return true
    }
}

extension CharacterAnimationView {
    /// The avatar's state as VoiceOver says it (D2-14): a phrase, never the raw state name.
    static func spokenState(_ state: AvatarState) -> String {
        switch state {
        case .idle: "ready"
        case .talking: "has a message for you"
        case .thinking: "thinking"
        case .working: "working"
        case .alert: "has something for you"
        case .waiting: "waiting for your answer"
        case .happy: "finished"
        case .sleeping: "quiet hours"
        }
    }
}
