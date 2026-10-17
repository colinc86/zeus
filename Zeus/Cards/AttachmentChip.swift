import AppKit
import SwiftUI
import ZeusDesign
import ZeusProtocol

/// Shared thread/peek attachment control. Targets are revalidated when activated, not trusted from display time.
struct AttachmentChip: View {
    enum Control: String { case open, more }
    enum Action: Equatable { case open, reveal, copy }
    enum TargetState { case open, revealOnly, missing, invalid }
    enum PreviewInteraction { case rest, hover, focused, expanded }
    let attachment: Attachment
    var compact = false
    var muted = false
    var entryID: String? = nil
    var threadFocus: FocusState<ConversationControlTarget?>.Binding? = nil
    var previewInteraction: PreviewInteraction? = nil
    var perform: @MainActor (Attachment, Action) -> String? = { Self.perform($0, $1) }
    @State private var hovering = false
    @State private var revealHovered = false
    @State private var expanded = false
    @State private var fullHeight: CGFloat = 0
    @State private var limitedHeight: CGFloat = 0
    @State private var feedback: String?
    @FocusState private var focused: Control?
    @Environment(\.zeusPalette) private var palette
    @Environment(\.openDocument) private var openDocument

    private var summary: String? {
        guard let value = attachment.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
    private var overflow: Bool { fullHeight > limitedHeight + 0.5 }
    private var isExpanded: Bool { expanded || previewInteraction == .expanded }
    private var isHovered: Bool { previewInteraction.map { $0 == .hover } ?? hovering }
    private var isFocused: Bool { previewInteraction.map { $0 == .focused } ?? (focused != nil) }
    var body: some View {
        let state = Self.targetState(attachment)
        let canReveal = attachment.kind != .url && state != .invalid
        let revealIcon = !compact && attachment.kind != .url && state == .open
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 0) {
                Button { activate(.open) } label: {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: ZeusAttachmentRow.symbol(for: attachment.kind)).font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(isHovered || isFocused ? palette.title : palette.secondaryText)
                            .frame(width: 14, height: 22).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(attachment.label).zeusFont(.body)
                                .foregroundStyle(muted || state == .missing || state == .invalid ? palette.mutedText : palette.text)
                                .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.trailing, revealIcon ? 24 : 0)
                            if let summary { summaryText(summary) }
                            if state == .missing || state == .invalid {
                                Text(state == .missing ? "Not found" : "Can't be opened")
                                    .zeusFont(.caption).foregroundStyle(palette.secondaryText)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(minHeight: 22).padding(.horizontal, 6).padding(.top, 6)
                        .padding(.bottom, !compact && summary != nil && (overflow || isExpanded) ? ZeusTheme.Spacing.xxs : 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).focusable(false).focusable(interactions: .edit).focusEffectDisabled()
                .focused($focused, equals: .open).id(target(.open))
                .accessibilityLabel(Self.accessibilityLabel(attachment))
                .accessibilityActions {
                    if state != .invalid { Button(state == .open ? "Open" : "Show in Finder") { activate(.open) } }
                    if !compact {
                        if canReveal && state == .open { Button("Show in Finder") { activate(.reveal) } }
                        Button(attachment.kind == .url ? "Copy Link" : "Copy Path") { activate(.copy) }
                        if overflow && !isExpanded { Button("Show the full summary") { expanded = true } }
                    }
                }
                .help(Self.tooltip(attachment))
                .onKeyPress(keys: [.return, .space]) { press in
                    if press.modifiers.contains(.command) {
                        guard press.key == .return, canReveal, !compact else { return .ignored }
                        activate(.reveal)
                    } else {
                        guard press.modifiers.intersection([.option, .control]).isEmpty else { return .ignored }
                        activate(.open)
                    }
                    return .handled
                }
                if !compact, summary != nil, overflow || isExpanded {
                    KeyboardButton(isExpanded ? "Less" : "More") { expanded = !isExpanded }
                        .buttonStyle(.plain).zeusFont(.caption).foregroundStyle(palette.title)
                        .focused($focused, equals: .more).frame(minHeight: 22).padding(.leading, 26).padding(.bottom, 6)
                        .accessibilityLabel(isExpanded ? "Show less" : "Show the full summary")
                        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed").id(target(.more))
                }
            }
            .background(PixelRoundedRectangle(steps: 1).fill(palette.field.opacity(isHovered ? 1 : 0.55)))
            .overlay(PixelRoundedRectangle(steps: 1).stroke(isFocused ? palette.focusRing : palette.fieldBorder, lineWidth: ZeusTheme.pixel).allowsHitTesting(false))
            .overlay(alignment: .topTrailing) {
                if revealIcon {
                    Button { activate(.reveal) } label: {
                        Image(systemName: "magnifyingglass").font(.system(size: 11)).frame(width: 20, height: 20)
                            .foregroundStyle(previewInteraction == nil && revealHovered ? palette.title : palette.secondaryText)
                            .opacity(isHovered || isFocused ? 1 : 0).contentShape(Rectangle())
                    }.buttonStyle(.plain).focusable(false).accessibilityHidden(true)
                        .onHover { revealHovered = $0 }.help("Show in Finder").padding(6)
                }
            }
            .onHover { hovering = $0 }
            .modifier(AttachmentContextMenu(enabled: !compact, attachment: attachment, state: state, action: activate))
            if let feedback, feedback != "Not found" {
                Text(feedback).zeusFont(.caption)
                    .foregroundStyle(feedback == AttachmentTarget.safetyCaption || feedback == "Not found" ? palette.secondaryText : palette.destructive)
            }
        }
        .onChange(of: focused) { _, value in if let value { threadFocus?.wrappedValue = target(value) } }
        .onChange(of: threadFocus?.wrappedValue) { _, target in
            guard let target, target.entryID == entryID else { return }
            focused = [Control.open, .more].first { self.target($0) == target }
        }
    }
    private func summaryText(_ text: String) -> some View {
        Text(text).zeusFont(.caption).foregroundStyle(muted ? palette.mutedText : palette.secondaryText)
            .lineLimit(isExpanded ? nil : compact ? 1 : 2).fixedSize(horizontal: false, vertical: true)
            .background {
                if !compact {
                    Text(text).zeusFont(.caption).fixedSize(horizontal: false, vertical: true).hidden()
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
                    Text(text).zeusFont(.caption).lineLimit(2).fixedSize(horizontal: false, vertical: true).hidden()
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { limitedHeight = $0 }
                }
            }
    }
    private func target(_ control: Control) -> ConversationControlTarget {
        .init(entryID: entryID ?? "attachment:" + attachment.id, controlID: control.rawValue + ":" + attachment.id)
    }
    private func activate(_ action: Action) {
        guard action == .copy || Self.targetState(attachment) != .invalid else { return }
        if action == .open, openDocument?(attachment, entryID) == true { return }
        feedback = perform(attachment, action)
    }
    static func targetState(_ attachment: Attachment) -> TargetState {
        guard let url = AttachmentTarget.url(for: attachment) else { return .invalid }
        if url.isFileURL && !FileManager.default.fileExists(atPath: url.path) { return .missing }
        if case .reveal? = AttachmentTarget.action(for: attachment) { return .revealOnly }
        return .open
    }
    static func accessibilityLabel(_ attachment: Attachment) -> String {
        let kind: String = switch attachment.kind { case .file: "File"; case .folder: "Folder"; case .url: "Link" }
        let state = targetState(attachment)
        return [kind + ": " + attachment.label, attachment.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
                state == .missing ? "Not found" : state == .invalid ? "Can't be opened" : nil]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }
    static func tooltip(_ attachment: Attachment) -> String {
        switch targetState(attachment) {
        case .missing: "Zeus will show the folder it was in."
        case .invalid: "Can't be opened"
        case .revealOnly: AttachmentTarget.safetyCaption
        case .open: attachment.kind == .url ? AttachmentTarget.url(for: attachment)?.host ?? attachment.target : AttachmentTarget.locationCaption(for: attachment)
        }
    }
    static func isMissing(_ attachment: Attachment) -> Bool { targetState(attachment) == .missing }
    static func revealTarget(_ attachment: Attachment) -> URL? {
        guard var url = AttachmentTarget.url(for: attachment), url.isFileURL else { return nil }
        url = url.resolvingSymlinksInPath()
        while !FileManager.default.fileExists(atPath: url.path) && url.path != "/" { url.deleteLastPathComponent() }
        return url
    }
    @MainActor static func perform(_ attachment: Attachment, _ action: Action) -> String? {
        if action == .copy {
            let value = attachment.kind == .url ? attachment.target : AttachmentTarget.url(for: attachment)?.path ?? attachment.target
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
            return nil
        }
        let reveal = action == .reveal
        if isMissing(attachment) {
            if let parent = revealTarget(attachment) { NSWorkspace.shared.activateFileViewerSelecting([parent]) }
            return "Not found" // Refresh the state if the file disappeared since the last render.
        }
        guard let resolved = AttachmentTarget.action(for: attachment, reveal: reveal) else { return "This attachment has an invalid target." }
        switch resolved {
        case .reveal(let url):
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return reveal ? nil : AttachmentTarget.safetyCaption
        case .open(let url): return NSWorkspace.shared.open(url) ? nil : "Could not open \(attachment.label)."
        }
    }
}
private struct AttachmentContextMenu: ViewModifier {
    let enabled: Bool
    let attachment: Attachment
    let state: AttachmentChip.TargetState
    let action: (AttachmentChip.Action) -> Void
    func body(content: Content) -> some View {
        if enabled {
            content.contextMenu {
                if state == .open { Button("Open") { action(.open) } }
                if attachment.kind != .url && state != .invalid { Button("Show in Finder") { action(.reveal) } }
                Button(attachment.kind == .url ? "Copy Link" : "Copy Path") { action(.copy) }
            }
        } else { content }
    }
}
