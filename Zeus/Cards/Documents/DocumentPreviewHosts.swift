import AppKit
import PDFKit
import Quartz
import SwiftUI

struct DocumentPDFHost: NSViewRepresentable {
    let model: DocumentViewerModel
    let page: DocumentViewerModel.Page
    let revision: Int
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePageContinuous; view.displayDirection = .vertical
        view.autoScales = true
        context.coordinator.view = view
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.selection), name: .PDFViewSelectionChanged, object: view)
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {
        context.coordinator.model = model
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
    }
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    @MainActor final class Coordinator: NSObject {
        var model: DocumentViewerModel
        weak var view: PDFView?
        var id: UUID?
        var revision = -1
        init(model: DocumentViewerModel) { self.model = model }
        @objc func selection() { model.selectedText = view?.currentSelection?.string ?? "" }
    }
}

struct DocumentQuickLookHost: NSViewRepresentable {
    let page: DocumentViewerModel.Page
    let revision: Int
    func makeNSView(context: Context) -> QLPreviewView { QLPreviewView(frame: .zero, style: .compact) }
    func updateNSView(_ view: QLPreviewView, context: Context) {
        guard context.coordinator.id != page.id || context.coordinator.revision != revision else { return }
        context.coordinator.id = page.id; context.coordinator.revision = revision
        guard DocumentLoader.renderer(for: page.url) == .quickLook else { view.previewItem = nil; return }
        view.previewItem = page.url as NSURL
        view.refreshPreviewItem()
    }
    static func dismantleNSView(_ view: QLPreviewView, coordinator: Coordinator) { view.close() }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var id: UUID?; var revision = -1 }
}

struct DocumentImageHost: NSViewRepresentable {
    let page: DocumentViewerModel.Page
    let revision: Int
    var reduceMotion: Bool
    func makeNSView(context: Context) -> NSScrollView {
        let view = NSScrollView()
        view.drawsBackground = false; view.hasVerticalScroller = true; view.hasHorizontalScroller = true
        view.allowsMagnification = true; view.minMagnification = 0.1; view.maxMagnification = 8
        let image = NSImageView(); image.imageScaling = .scaleNone; image.animates = !reduceMotion
        view.documentView = image
        return view
    }
    func updateNSView(_ view: NSScrollView, context: Context) {
        guard let image = view.documentView as? NSImageView else { return }
        image.animates = !reduceMotion
        guard context.coordinator.id != page.id || context.coordinator.revision != revision else { return }
        let same = context.coordinator.id == page.id
        context.coordinator.id = page.id; context.coordinator.revision = revision
        guard DocumentLoader.renderer(for: page.url) == .image else { image.image = nil; return }
        image.image = NSImage(contentsOf: page.url)
        if let size = image.image?.size {
            image.frame.size = size
            if !same { view.magnification = min(1, max(0.1, view.contentSize.width / max(1, size.width))) }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var id: UUID?; var revision = -1 }
}
