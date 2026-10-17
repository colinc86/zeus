import AppKit
import SwiftUI
import ZeusDesign

/// Read-only native selection and wrapping, shared by source, text and rendered Markdown.
struct DocumentTextHost: NSViewRepresentable {
    let model: DocumentViewerModel
    let page: DocumentViewerModel.Page
    let text: NSAttributedString
    let revision: Int
    var quote: () -> Void

    func makeNSView(context: Context) -> DocumentTextScrollView {
        let view = DocumentTextScrollView()
        view.textView.delegate = context.coordinator
        return view
    }
    func updateNSView(_ view: DocumentTextScrollView, context: Context) {
        view.textView.linkTextAttributes = [.foregroundColor: NSColor(context.environment.zeusPalette.link), .underlineStyle: NSUnderlineStyle.single.rawValue]
        context.coordinator.model = model
        context.coordinator.url = page.url
        view.textView.quote = quote
        view.update(text, pageID: page.id, revision: revision, source: page.source, saved: model.offsets[page.id])
        view.find(model.findText, index: model.findIndex, request: model.findRequest, palette: context.environment.zeusPalette) { count in
            Task { @MainActor [weak model] in if model?.findCount != count { model?.findCount = count } }
        }
        view.onScroll = { [weak model] point in model?.offsets[page.id] = point }
    }
    func makeCoordinator() -> Coordinator { Coordinator(model: model, url: page.url) }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var model: DocumentViewerModel
        var url: URL
        init(model: DocumentViewerModel, url: URL) { self.model = model; self.url = url }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            let selection = (view.string as NSString).substring(with: view.selectedRange())
            Task { @MainActor [weak model] in if model?.selectedText != selection { model?.selectedText = selection } }
        }
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let reference = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
            if let local = DocumentLoader.localLink(reference, document: url) { model.navigate(local) }
            else if let target = URL(string: reference), ["http", "https"].contains(target.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(target) }
            return true
        }
    }
}

@MainActor final class DocumentTextView: NSTextView {
    var quote: (() -> Void)?
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let item = NSMenuItem(title: "Quote in Reply", action: #selector(quoteSelection), keyEquivalent: "")
        item.target = self; item.isEnabled = selectedRange().length > 0
        menu.insertItem(.separator(), at: 0); menu.insertItem(item, at: 0)
        return menu
    }
    @objc private func quoteSelection() { quote?() }
}

@MainActor final class DocumentTextScrollView: NSScrollView {
    let textView = DocumentTextView(frame: .zero)
    var onScroll: ((CGPoint) -> Void)?
    private var pageID: UUID?
    private var revision = -1
    private var source = false
    private var previousText: NSAttributedString?
    private var findKey = ""
    override init(frame: NSRect) {
        super.init(frame: frame)
        drawsBackground = false; hasVerticalScroller = true; borderType = .noBorder
        textView.isEditable = false; textView.isSelectable = true; textView.drawsBackground = false
        textView.isRichText = true; textView.importsGraphics = false
        textView.isVerticallyResizable = true; textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 320, height: CGFloat.greatestFiniteMagnitude)
        documentView = textView
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: contentView)
        setAccessibilityLabel("Document contents")
    }
    required init?(coder: NSCoder) { nil }
    @objc private func scrolled() { onScroll?(contentView.bounds.origin) }
    func find(_ query: String, index: Int, request: Int, palette: ZeusPalette, count: (Int) -> Void) {
        let key = "\(query):\(index):\(request):\(revision)"
        guard key != findKey else { return }; findKey = key
        let text = textView.string as NSString
        textView.layoutManager?.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: text.length))
        textView.layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: text.length))
        var ranges: [NSRange] = []; var start = 0
        if !query.isEmpty {
            while start < text.length {
                let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: NSRange(location: start, length: text.length - start))
                guard range.location != NSNotFound else { break }
                ranges.append(range); start = NSMaxRange(range)
            }
        }
        count(ranges.count)
        for range in ranges { textView.layoutManager?.addTemporaryAttribute(.backgroundColor, value: NSColor(palette.accent).withAlphaComponent(0.35), forCharacterRange: range) }
        if !ranges.isEmpty {
            let range = ranges[((index % ranges.count) + ranges.count) % ranges.count]
            textView.layoutManager?.addTemporaryAttribute(.backgroundColor, value: NSColor(palette.accent), forCharacterRange: range)
            textView.layoutManager?.addTemporaryAttribute(.foregroundColor, value: NSColor(palette.onAccent), forCharacterRange: range)
            textView.scrollRangeToVisible(range)
        }
    }
    func update(_ value: NSAttributedString, pageID: UUID, revision: Int, source: Bool, saved: CGPoint?) {
        guard self.pageID != pageID || self.revision != revision || self.source != source || previousText?.isEqual(to: value) != true else { return }
        let same = self.pageID == pageID
        let oldExtent = max(0, textView.frame.height - contentSize.height)
        let fraction = oldExtent > 0 ? contentView.bounds.minY / oldExtent : 0
        let offset = same ? contentView.bounds.origin : saved ?? .zero
        let selection = textView.selectedRange()
        let contentChanged = same && self.revision != revision
        self.pageID = pageID; self.revision = revision; self.source = source; previousText = value; findKey = ""
        textView.textStorage?.setAttributedString(value)
        textView.frame.size.width = contentSize.width
        if let container = textView.textContainer { textView.layoutManager?.ensureLayout(for: container) }
        textView.sizeToFit()
        let length = value.length
        textView.setSelectedRange(same ? NSRange(location: min(selection.location, length), length: min(selection.length, max(0, length - selection.location))) : NSRange(location: 0, length: 0))
        let extent = max(0, textView.frame.height - contentSize.height)
        contentView.scroll(to: NSPoint(x: 0, y: min(extent, contentChanged ? fraction * extent : offset.y)))
        reflectScrolledClipView(contentView)
    }
}
