import AppKit
import SwiftUI
import ZeusDesign
import ZeusProtocol

/// The measured chip flow stays above the composer. Larger drafts scroll locally within its bounded height.
struct ContextDraftAttachments: View {
    @Bindable var model: ConversationModel
    var managed = false
    var workInFolder: (String) -> Void = { _ in }
    @State private var height: CGFloat = 32
    @Environment(\.zeusPalette) private var palette
    var body: some View {
        if let caption = model.contextCaption {
            Text(caption).zeusFont(.caption).foregroundStyle(palette.secondaryText).fixedSize(horizontal: false, vertical: true)
        }
        if !model.draftAttachments.isEmpty {
            if height > 120 {
                ScrollView(.vertical) { chips }.defaultScrollAnchor(.top).frame(height: 120)
            } else { chips }
        }
    }
    private var chips: some View {
        ZeusChipFlow(spacing: 6) {
            ForEach(model.draftAttachments, id: \.id) { item in
                ContextAttachmentChip(item: item, context: model.contextItems[item.id], managed: managed,
                    workInFolder: workInFolder, remove: { model.removeAttachment(id: item.id) }).disabled(model.isSending)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .contain).accessibilityLabel("Draft attachments")
            .onGeometryChange(for: CGFloat.self) { ceil($0.size.height) } action: { if height != $0 { height = $0 } }
    }
}

private struct ContextAttachmentChip: View {
    let item: Attachment
    let context: ContextDraftItem?
    let managed: Bool
    let workInFolder: (String) -> Void
    let remove: () -> Void
    @State private var previewing = false
    private var picture: NSImage? { context?.kind == .picture ? NSImage(contentsOfFile: item.target) : nil }
    @ViewBuilder var body: some View {
        if let picture {
            chip(thumbnail: Image(nsImage: picture))
                .onHover { previewing = $0 }
                .popover(isPresented: $previewing, arrowEdge: .top) {
                    Image(nsImage: picture).resizable().scaledToFit().frame(maxWidth: 480, maxHeight: 320).padding(8).accessibilityLabel("Covered picture preview")
                }
        } else { chip(thumbnail: nil) }
    }
    private func chip(thumbnail: Image?) -> some View {
        ZeusAttachmentChip(item, thumbnail: thumbnail,
            actionTitle: item.kind == .folder && managed ? "Work in this folder" : nil,
            onAction: item.kind == .folder && managed ? { workInFolder(item.target) } : nil, onRemove: remove)
            .help(context?.preview ?? item.label)
    }
}
