import AppKit
import PDFKit
import Quartz
import ZeusDesign
import SwiftUI

struct DocumentPDFHost: NSViewRepresentable {
    let model: DocumentViewerModel
    let page: DocumentViewerModel.Page
    let revision: Int
    @Environment(\.zeusPalette) private var palette
    func makeNSView(context: Context) -> PDFView {
        let view = DocumentPDFView(frame: NSRect(x: 0, y: 0, width: 320, height: 400))
        view.displayMode = .singlePageContinuous; view.displayDirection = .vertical
        view.autoScales = true
        context.coordinator.view = view
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.selection), name: .PDFViewSelectionChanged, object: view)
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.pageChanged), name: .PDFViewPageChanged, object: view)
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {
        context.coordinator.model = model
        view.backgroundColor = NSColor(palette.panel)
        (view as? DocumentPDFView)?.quote = { model.quoteRequest += 1 }
        context.coordinator.commands(view)
        guard context.coordinator.revision != revision || context.coordinator.id != page.id else { return }
        let index = view.currentPage.flatMap { view.document?.index(for: $0) }
        let destination = view.currentDestination?.point
        context.coordinator.id = page.id; context.coordinator.revision = revision
        // Revalidate after every change, including a path replaced with an executable or symlink.
        guard DocumentLoader.renderer(for: page.url) == .pdf else { view.document = nil; return }
        view.document = PDFDocument(url: page.url)
        if let index, let document = view.document, let target = document.page(at: min(index, document.pageCount - 1)) {
            view.go(to: PDFDestination(page: target, at: destination ?? .zero))
        }
        context.coordinator.findKey = ""; context.coordinator.commands(view); context.coordinator.pageChanged()
    }
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    @MainActor final class Coordinator: NSObject {
        var model: DocumentViewerModel
        weak var view: PDFView?
        var id: UUID?
        var revision = -1
        var zoomRequest = 0
        var findKey = ""
        init(model: DocumentViewerModel) { self.model = model }
        @objc func selection() {
            let text = view?.currentSelection?.string ?? ""
            Task { @MainActor [weak model] in model?.selectedText = text }
        }
        @objc func pageChanged() {
            guard let document = view?.document, let page = view?.currentPage else { return }
            let value = "Page \(document.index(for: page) + 1) of \(document.pageCount)"
            Task { @MainActor [weak model] in if model?.pdfPage != value { model?.pdfPage = value } }
        }
        func commands(_ view: PDFView) {
            if zoomRequest != model.zoomRequest {
                zoomRequest = model.zoomRequest
                switch model.zoomDirection { case 0: view.autoScales = true; case 1: view.zoomIn(nil); default: view.zoomOut(nil) }
            }
            let key = "\(model.findText):\(model.findIndex):\(revision)"
            guard key != findKey else { return }; findKey = key
            let matches = model.findText.isEmpty ? [] : view.document?.findString(model.findText, withOptions: [.caseInsensitive, .diacriticInsensitive]) ?? []
            Task { @MainActor [weak model] in if model?.findCount != matches.count { model?.findCount = matches.count } }
            view.highlightedSelections = matches
            if !matches.isEmpty {
                let index = ((model.findIndex % matches.count) + matches.count) % matches.count
                view.setCurrentSelection(matches[index], animate: false); view.go(to: matches[index])
            }
        }
    }
}

struct DocumentQuickLookHost: NSViewRepresentable {
    let page: DocumentViewerModel.Page
    let revision: Int
    func makeNSView(context: Context) -> QLPreviewView {
        let view: QLPreviewView = QLPreviewView(frame: .zero, style: .compact)
        view.shouldCloseWithWindow = false
        return view
    }
    func updateNSView(_ view: QLPreviewView, context: Context) {
        guard context.coordinator.id != page.id || context.coordinator.revision != revision else { return }
        let same = context.coordinator.id == page.id
        let state = same ? view.displayState : nil
        context.coordinator.id = page.id; context.coordinator.revision = revision
        guard DocumentLoader.renderer(for: page.url) == .quickLook else { view.previewItem = nil; return }
        if !same { view.previewItem = page.url as NSURL }
        view.refreshPreviewItem()
        if let state { view.displayState = state }
    }
    static func dismantleNSView(_ view: QLPreviewView, coordinator: Coordinator) { view.close() }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var id: UUID?; var revision = -1; var zoomRequest = 0 }
}

struct DocumentImageHost: NSViewRepresentable {
    let model: DocumentViewerModel
    let page: DocumentViewerModel.Page
    let revision: Int
    var reduceMotion: Bool
    func makeNSView(context: Context) -> DocumentImageScrollView {
        let view = DocumentImageScrollView()
        view.drawsBackground = false; view.hasVerticalScroller = true; view.hasHorizontalScroller = true
        view.allowsMagnification = true; view.minMagnification = 0.1; view.maxMagnification = 8
        let image = NSImageView(); image.imageScaling = .scaleProportionallyDown; image.animates = !reduceMotion
        view.documentView = image
        return view
    }
    func updateNSView(_ view: DocumentImageScrollView, context: Context) {
        guard let image = view.documentView as? NSImageView else { return }
        image.animates = !reduceMotion
        if context.coordinator.zoomRequest != model.zoomRequest {
            context.coordinator.zoomRequest = model.zoomRequest
            if model.zoomDirection == 0 { view.fitImage() }
            view.magnification = model.zoomDirection == 0 ? 1 : min(view.maxMagnification, max(view.minMagnification, view.magnification * (model.zoomDirection > 0 ? 1.25 : 0.8)))
        }
        guard context.coordinator.id != page.id || context.coordinator.revision != revision else { return }
        let same = context.coordinator.id == page.id
        context.coordinator.id = page.id; context.coordinator.revision = revision
        guard DocumentLoader.renderer(for: page.url) == .image else { image.image = nil; return }
        image.image = NSImage(contentsOf: page.url)
        if let size = image.image?.size {
            view.naturalSize = size
            if !same { view.needsInitialFit = true; view.needsLayout = true }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var id: UUID?; var revision = -1; var zoomRequest = 0 }
}

@MainActor final class DocumentPDFView: PDFView {
    var quote: (() -> Void)?
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let item = NSMenuItem(title: "Quote in Reply", action: #selector(quoteSelection), keyEquivalent: "")
        item.target = self; item.isEnabled = currentSelection?.string?.isEmpty == false
        menu.insertItem(.separator(), at: 0); menu.insertItem(item, at: 0)
        return menu
    }
    @objc private func quoteSelection() { quote?() }
}

@MainActor final class DocumentImageScrollView: NSScrollView {
    var naturalSize = NSSize.zero
    var needsInitialFit = true
    private var fittedSize = NSSize.zero
    override func layout() {
        super.layout()
        if contentSize.width > 0 && (needsInitialFit || abs(fittedSize.width - contentSize.width) > 1 || abs(fittedSize.height - contentSize.height) > 1) { fitImage() }
    }
    func fitImage() {
        guard naturalSize.width > 0, contentSize.width > 0 else { return }
        needsInitialFit = false; fittedSize = contentSize
        let factor = min(1, contentSize.width / naturalSize.width)
        documentView?.frame.size = NSSize(width: contentSize.width, height: max(contentSize.height, naturalSize.height * factor))
        magnification = 1
    }
}
