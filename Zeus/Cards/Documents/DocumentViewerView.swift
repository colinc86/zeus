import AppKit
import SwiftUI
import ZeusDesign
import ZeusProtocol

/// App-owned renderer and navigation composition; all chrome comes from ZeusDesign.
struct DocumentViewerView: View {
    @Bindable var model: DocumentViewerModel
    let conversation: ConversationModel
    let back: () -> Void
    let context: () -> Void
    @Environment(\.zeusPalette) private var palette
    @Environment(\.zeusFontChoice) private var font
    @Environment(\.zeusFontScale) private var scale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showLoading = false
    @State private var safetyCaption = false
    @State private var folderDriver = ConversationScrollDriver()

    var body: some View {
        if let page = model.current {
            VStack(spacing: 0) {
                ZeusViewerHeader(header(page), appIcon: appIcon(page), menu: menu(page), onBack: back,
                    onOpen: { model.openExternally(page) }, onReveal: { model.revealExternally(page) },
                    onExpand: { model.expanded.toggle() }, onStep: { _ = model.step($0 == .previous ? -1 : 1) })
                if !page.isSnapshot {
                    ZeusViewerContextLine(origin(page), trailing: model.pdfPage,
                        updateToken: model.updatedAt == nil ? 0 : model.revision, action: context)
                }
                if model.findVisible {
                    ZeusFindBar(text: $model.findText, current: model.findCount > 0 ? ((model.findIndex % model.findCount) + model.findCount) % model.findCount + 1 : 0,
                        total: model.findText.isEmpty ? nil : model.findCount, focusRequest: model.findRequest,
                        onPrevious: { model.findIndex -= 1 }, onNext: { model.findIndex += 1 }, onDone: { model.findVisible = false })
                        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                }
                ZStack {
                    content(page).id(page.id).frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: model.navigationDirection > 0 ? .trailing : .leading), removal: .move(edge: model.navigationDirection > 0 ? .leading : .trailing)))
                }.clipped()
                    .animation(.easeOut(duration: reduceMotion ? 0.12 : 0.18), value: page.id)
            }
            .background(palette.panel)
            .animation(.easeOut(duration: reduceMotion ? 0 : 0.12), value: model.findVisible)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(page.content?.renderer == .folder ? "Folder" : "Document"): \(page.attachment.label)")
            .task(id: model.loading) {
                showLoading = false
                guard model.loading else { return }
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                showLoading = true
            }
            .onChange(of: model.quoteRequest) { model.quote(in: conversation); model.composerRequest += 1 }
            .onChange(of: model.findText) { model.findIndex = 0 }
            .onChange(of: model.current?.id, initial: true) {
                NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                    userInfo: [.announcement: "Showing \(page.attachment.label)", .priority: NSAccessibilityPriorityLevel.medium.rawValue])
            }
            .onChange(of: model.updatedAt) {
                guard model.updatedAt != nil else { return }
                NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                    userInfo: [.announcement: "Document updated", .priority: NSAccessibilityPriorityLevel.medium.rawValue])
            }
        }
    }
    private func header(_ page: DocumentViewerModel.Page) -> ZeusViewerHeaderModel {
        let previous = model.pages.dropLast().last
        let step = model.attachmentPosition?.split(separator: "/").compactMap { Int($0) }
        return .init(title: page.attachment.label, location: page.isSnapshot ? nil : AttachmentTarget.locationCaption(for: page.attachment),
            backTitle: previous.map { $0.content?.renderer == .folder ? $0.attachment.label : "Back" } ?? "Messages",
            openTitle: openTitle(page), canOpen: !page.isSnapshot, canReveal: !page.isSnapshot, expanded: model.expanded,
            step: step.flatMap { $0.count == 2 ? .init(index: $0[0], count: $0[1]) : nil })
    }
    private func openTitle(_ page: DocumentViewerModel.Page) -> String {
        if page.isSnapshot { return "Open" }
        return page.content?.renderer == .folder ? ZeusViewerHeaderModel.folderOpenTitle : ZeusViewerHeaderModel.openTitle(app: DocumentActions.applicationName(for: page.url))
    }
    private func appIcon(_ page: DocumentViewerModel.Page) -> Image? {
        guard !page.isSnapshot else { return nil }
        return DocumentActions.application(for: page.url).map { Image(nsImage: NSWorkspace.shared.icon(forFile: $0.path)) }
    }
    private func origin(_ page: DocumentViewerModel.Page) -> ZeusViewerContextLine.Origin {
        if let previous = model.pages.dropLast().last {
            return previous.content?.renderer == .folder ? .folder(previous.attachment.label) : .link(previous.attachment.label)
        }
        return .message(page.context ?? page.attachment.summary ?? page.attachment.label)
    }
    private func menu(_ page: DocumentViewerModel.Page) -> [ZeusViewerMenuItem] {
        if page.isSnapshot {
            return [.init("Copy Text", action: { DocumentActions.copy(page) }),
                    .init("Find…", action: { model.handle(.find, conversation: conversation) })]
        }
        var items: [ZeusViewerMenuItem] = [
            .init("Copy Path", action: { DocumentActions.copy(page) }),
            .init("Open With", children: NSWorkspace.shared.urlsForApplications(toOpen: page.url).map { app in
                .init(FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: ""), id: app.path,
                    action: { DocumentActions.open(page, application: app) })
            })
        ]
        if page.content?.renderer == .markdown {
            items.append(.init(page.source ? "Show Rendered" : "Show Source", action: { model.toggleSource() }))
        }
        items.append(.init("Ask About This", action: { model.ask(in: conversation); model.composerRequest += 1 }))
        items.append(.init("Quote in Reply", isEnabled: !model.selectedText.isEmpty, action: { model.quote(in: conversation); model.composerRequest += 1 }))
        if model.supportsFind { items.append(.init("Find…", action: { model.handle(.find, conversation: conversation) })) }
        return items
    }
    @ViewBuilder private func content(_ page: DocumentViewerModel.Page) -> some View {
        if let value = page.content {
            switch value.renderer {
            case .text, .markdown:
                if value.text?.isEmpty != false { state(page, message: ZeusViewerStatus.Copy.emptyFile) }
                else {
                    VStack(spacing: 0) {
                        GeometryReader { geometry in
                        DocumentTextHost(model: model, page: page,
                            text: DocumentTextStyling.make(page, revision: model.revision, choice: font, scale: scale, palette: palette, width: geometry.size.width), revision: model.revision,
                            quote: { model.quote(in: conversation); model.composerRequest += 1 })
                        }
                        if value.truncated {
                            ZeusViewerStatus(message: ZeusViewerStatus.Copy.tooLarge,
                                actions: [.init(ZeusViewerStatus.Copy.openForRest(app: DocumentActions.applicationName(for: page.url)), action: { DocumentActions.open(page) })], footer: true)
                        }
                    }
                }
            case .image: DocumentImageHost(model: model, page: page, revision: model.revision, reduceMotion: reduceMotion)
            case .pdf: DocumentPDFHost(model: model, page: page, revision: model.revision)
            case .quickLook: DocumentQuickLookHost(page: page, revision: model.revision)
            case .folder: folder(page, value: value)
            case .missing: state(page, message: ZeusViewerStatus.Copy.missing, missing: true)
            case .unsupported: state(page, message: value.error == nil ? ZeusViewerStatus.Copy.unsupported : ZeusViewerStatus.Copy.unreadable)
            case .revealOnly: state(page, message: ZeusViewerStatus.Copy.revealOnly, missing: true)
            }
        } else if showLoading { Text(ZeusViewerStatus.Copy.loading).zeusFont(.caption).foregroundStyle(palette.secondaryText) }
        else { Color.clear }
    }
    private func state(_ page: DocumentViewerModel.Page, message: String, missing: Bool = false) -> some View {
        let actions: [ZeusViewerStatus.Action] = missing
            ? [.init("Show in Finder", style: .primary, action: { DocumentActions.reveal(page) })]
            : [.init(openTitle(page), style: .primary, action: { DocumentActions.open(page) }), .init("Show in Finder", action: { DocumentActions.reveal(page) })]
        return ZeusViewerStatus(icon: Image(nsImage: NSWorkspace.shared.icon(forFile: page.url.path)), name: page.attachment.label,
            missing: missing, detail: missing ? nil : page.content.flatMap { value in ZeusViewerStatus.Copy.detail(kind: page.url.pathExtension.isEmpty ? nil : page.url.pathExtension.uppercased(), size: ByteCountFormatter.string(fromByteCount: value.size, countStyle: .file), modified: value.modified?.formatted(.dateTime.day().month(.abbreviated).hour().minute())) }, message: message, actions: actions)
    }
    @ViewBuilder private func folder(_ page: DocumentViewerModel.Page, value: DocumentContent) -> some View {
        if value.items.isEmpty { state(page, message: ZeusViewerStatus.Copy.emptyFolder) }
        else {
            ScrollView {
                LazyVStack(spacing: ZeusTheme.Spacing.xxs) {
                    ForEach(value.items.prefix(500)) { item in
                        ZeusFolderRow(name: item.name, kind: item.kind,
                            modified: item.modified.map { DocumentLoader.modifiedLabel($0) } ?? "", symbol: item.isFolder ? "folder.fill" : "doc.fill") {
                            if !model.navigate(item.url) {
                                NSWorkspace.shared.activateFileViewerSelecting([item.url]); safetyCaption = true
                                Task { try? await Task.sleep(for: .seconds(4)); safetyCaption = false }
                            }
                        }
                    }
                    if value.items.count > 500 {
                        KeyboardButton("and \(value.items.count - 500) more · Show in Finder") { DocumentActions.reveal(page) }
                            .buttonStyle(.plain).zeusFont(.caption).foregroundStyle(palette.title)
                    }
                    if safetyCaption { Text(AttachmentTarget.safetyCaption).zeusFont(.caption).foregroundStyle(palette.secondaryText) }
                }.padding(ZeusTheme.Spacing.m)
                    .background(ConversationScrollProbe(driver: folderDriver))
            }
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, value in model.offsets[page.id] = CGPoint(x: 0, y: value) }
            .task(id: page.id) {
                let saved = model.offsets[page.id]?.y ?? 0
                await Task.yield(); folderDriver.scroll(to: saved)
            }
        }
    }
}
