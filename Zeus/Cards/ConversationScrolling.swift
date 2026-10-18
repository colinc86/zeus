import AppKit
import SwiftUI

/// Native scrolling preserves focus and scrolls by distance, rather than skipping tall bubbles.
enum ConversationScrollCommand: Equatable {
    case line(Int), page(Int), oldest, latest
}

enum ConversationScrollPolicy {
    static func command(keyCode: UInt16, command: Bool, otherModifiers: Bool, composerFocused: Bool,
                        empty: Bool, firstLine: Bool, lastLine: Bool) -> ConversationScrollCommand? {
        if keyCode == 116 { return .page(-1) }
        if keyCode == 121 { return .page(1) }
        guard keyCode == 126 || keyCode == 125, !otherModifiers else { return nil }
        if command { return keyCode == 126 ? .oldest : .latest }
        if !composerFocused || empty || (keyCode == 126 ? firstLine : lastLine) {
            return .line(keyCode == 126 ? -1 : 1)
        }
        return nil
    }

    /// Use laid-out visual lines, so wrapping behaves the same as explicit newlines.
    @MainActor static func caretLines(in editor: NSTextView) -> (first: Bool, last: Bool) {
        let count = (editor.string as NSString).length
        guard count > 0 else { return (true, true) }
        let selection = editor.selectedRange()
        guard selection.length == 0 else { return (false, false) }
        let caret = min(selection.location, count)
        guard let layout = editor.layoutManager, let container = editor.textContainer else {
            let text = editor.string as NSString
            let before = text.substring(to: caret), after = text.substring(from: caret)
            return (!before.contains("\n"), !after.contains("\n"))
        }
        layout.ensureLayout(for: container)
        guard layout.numberOfGlyphs > 0 else { return (true, true) }
        let first = layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        let last = layout.extraLineFragmentTextContainer == nil
            ? layout.lineFragmentRect(forGlyphAt: layout.numberOfGlyphs - 1, effectiveRange: nil) : layout.extraLineFragmentRect
        let current: NSRect = caret == count && layout.extraLineFragmentTextContainer != nil
            ? layout.extraLineFragmentRect
            : layout.lineFragmentRect(forGlyphAt: min(layout.glyphIndexForCharacter(at: min(caret, count - 1)), layout.numberOfGlyphs - 1), effectiveRange: nil)
        return (abs(current.minY - first.minY) < 1, abs(current.minY - last.minY) < 1)
    }
}

@MainActor final class ConversationScrollDriver: NSObject {
    weak var scrollView: NSScrollView? {
        didSet { observeDocument() }
    }
    private weak var observedDocument: NSView?
    private var following = false
    private var restoration: (offset: CGFloat, completion: (@MainActor () -> Void)?)?
    var isRestoring: Bool { restoration != nil }

    /// Keep the requested position through native layout and focus updates, until the next user navigation.
    func restore(to offset: CGFloat, completion: (@MainActor () -> Void)? = nil) {
        following = false
        restoration = (offset, completion ?? restoration?.completion)
        scheduleFollow()
    }
    func stopRestoring() { restoration = nil }

    private var newestTop: CGFloat?
    private var layoutTask: Task<Void, Never>?

    deinit { NotificationCenter.default.removeObserver(self) }

    private func observeDocument() {
        guard let document = scrollView?.documentView, observedDocument !== document else { return }
        NotificationCenter.default.removeObserver(self)
        observedDocument = document
        document.postsFrameChangedNotifications = true
        document.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(documentLayoutChanged),
                                              name: NSView.frameDidChangeNotification, object: document)
        NotificationCenter.default.addObserver(self, selector: #selector(documentLayoutChanged),
                                              name: NSView.boundsDidChangeNotification, object: document)
        if let clip = scrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(documentLayoutChanged),
                name: NSView.boundsDidChangeNotification, object: clip)
            NotificationCenter.default.addObserver(self, selector: #selector(documentLayoutChanged),
                name: NSView.frameDidChangeNotification, object: clip)
        }
        scheduleFollow()
    }

    /// Retain the follow request until actual native document layout catches up with SwiftUI.
    /// Document-size notifications retry it; there is no polling clock while the panel is idle.
    func followLatest(newestMessageTop: CGFloat?) {
        stopRestoring()
        following = true
        newestTop = newestMessageTop
        scheduleFollow()
    }

    func stopFollowing() {
        following = false
        layoutTask?.cancel()
        layoutTask = nil
    }

    @objc private func documentLayoutChanged() { scheduleFollow() }

    private func scheduleFollow() {
        guard following || restoration != nil, layoutTask == nil else { return }
        layoutTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            self.layoutTask = nil
            if let request = self.restoration {
                self.scroll(to: request.offset)
                if let viewport = self.viewport, abs(viewport.offset - request.offset) < 1 {
                    self.restoration?.completion = nil
                    request.completion?()
                }
                return
            }
            guard self.following, let viewport = self.viewport else { return }
            self.scroll(to: ConversationAutoScroll.targetOffset(viewport: viewport,
                                                                newestMessageTop: self.newestTop, pinned: true))
        }
    }

    var viewport: ConversationViewport? {
        guard let scrollView, let document = scrollView.documentView else { return nil }
        let clip = scrollView.contentView
        let maximum = max(0, document.bounds.height - clip.bounds.height)
        return .init(offset: document.isFlipped ? clip.bounds.minY : maximum - clip.bounds.minY,
                     contentHeight: document.bounds.height, height: clip.bounds.height)
    }

    func scroll(to offset: CGFloat) {
        guard let scrollView, let document = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let maximum = max(0, document.bounds.height - clip.bounds.height)
        let top = min(maximum, max(0, offset))
        let y = document.isFlipped ? top : maximum - top
        guard abs(clip.bounds.minY - y) > 0.5 else { return }
        clip.scroll(to: CGPoint(x: clip.bounds.minX, y: y))
        scrollView.reflectScrolledClipView(clip)
    }

    func perform(_ command: ConversationScrollCommand) {
        stopRestoring()
        guard let scrollView, let document = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let amount: CGFloat = switch command {
        case .line(let direction): CGFloat(direction) * 40
        case .page(let direction): CGFloat(direction) * max(40, clip.bounds.height * 0.9)
        case .oldest, .latest: 0
        }
        let delta = document.isFlipped ? amount : -amount
        let maximum = max(0, document.bounds.height - clip.bounds.height)
        let y: CGFloat = switch command {
        case .oldest: document.isFlipped ? 0 : maximum
        case .latest: document.isFlipped ? maximum : 0
        default: min(max(clip.bounds.minY + delta, 0), maximum)
        }
        clip.scroll(to: CGPoint(x: clip.bounds.minX, y: y))
        scrollView.reflectScrolledClipView(clip)
    }
}

struct ConversationScrollProbe: NSViewRepresentable {
    let driver: ConversationScrollDriver
    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        view.connect = { driver.scrollView = $0 }
        return view
    }
    func updateNSView(_ view: Probe, context: Context) { view.attach() }
    @MainActor final class Probe: NSView {
        var connect: ((NSScrollView) -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attach() }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); attach() }
        func attach() { if let enclosingScrollView { connect?(enclosingScrollView) } }
    }
}
