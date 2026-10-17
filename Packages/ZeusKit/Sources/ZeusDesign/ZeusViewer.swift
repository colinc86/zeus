import SwiftUI
import ZeusProtocol

// The document viewer's chrome (CONTRACT §10, docs/design/CONVERSATION.md §21). The app owns the viewer state,
// the renderers and the panel resizing; these views own the look, the copy and the keys of the header, the
// context line, the empty and error states, folder rows and the find bar.

// MARK: - Header

/// What the viewer header shows (§21.3). The app maps its state to this with a pure function, so the copy lives here.
public struct ZeusViewerHeaderModel: Equatable, Sendable {
    /// "2/3": the attachment's 1-based position among its message's attachments.
    public struct Step: Equatable, Sendable {
        public var index: Int
        public var count: Int
        public init(index: Int, count: Int) {
            self.index = index
            self.count = count
        }
        public var text: String { "\(index)/\(count)" }
        public var hasPrevious: Bool { index > 1 }
        public var hasNext: Bool { index < count }
    }

    /// The 12 × 12 pixel icons of the header, drawn like the strip's (`ZeusStatusStripModel.Item.rows`).
    public enum Icon: String, CaseIterable, Sendable {
        case expand, collapse

        /// Top row first; "#" is filled.
        public var rows: [String] {
            switch self {
            case .expand: [
                "###......###",
                "#..........#",
                "#..........#",
                "............",
                "............",
                "............",
                "............",
                "............",
                "............",
                "#..........#",
                "#..........#",
                "###......###",
            ]
            case .collapse: [
                "............",
                "............",
                "..#......#..",
                "..#......#..",
                "..###..###..",
                "............",
                "............",
                "..###..###..",
                "..#......#..",
                "..#......#..",
                "............",
                "............",
            ]
            }
        }
    }

    /// The file or folder name.
    public var title: String
    /// The folder it lives in, in `~` form (`AttachmentTarget.locationCaption`); nil for a folder listing's own row.
    public var location: String?
    /// What Back pops to: "Messages", a folder's name, or "Back" for a linked document.
    public var backTitle: String
    /// "Open in Keynote", "Open" (no default app) or "Open in Finder" (a folder).
    public var openTitle: String
    /// Whether Show in Finder applies (not for a missing root).
    public var canReveal: Bool
    /// Whether the panel is at reading size; flips the icon and its tooltip.
    public var expanded: Bool
    /// Present when the message has several attachments.
    public var step: Step?

    public init(title: String, location: String? = nil, backTitle: String = messagesBackTitle, openTitle: String,
                canReveal: Bool = true, expanded: Bool = false, step: Step? = nil) {
        self.title = title
        self.location = location
        self.backTitle = backTitle
        self.openTitle = openTitle
        self.canReveal = canReveal
        self.expanded = expanded
        self.step = step
    }

    public static let messagesBackTitle = "Messages"
    public static let linkedBackTitle = "Back"
    public static let folderOpenTitle = "Open in Finder"
    public static let revealTitle = "Show in Finder"
    // Tooltips are system-font strings (`.help`), so they may use ⇧ and ⌃, written as escapes because the pixel
    // font has no glyph for them and the glyph audit scans literals.
    public static let revealTooltip = "Show in Finder (⌘\u{21E7}R)"
    public static let moreTitle = "More"
    public static let previousTooltip = "Previous attachment (\u{2303}⌘←)"
    public static let nextTooltip = "Next attachment (\u{2303}⌘→)"

    /// "Open in Keynote", or "Open" when no app claims the file.
    nonisolated public static func openTitle(app: String?) -> String {
        app.map { "Open in \($0)" } ?? "Open"
    }

    public var openTooltip: String { "\(openTitle) (⌘O)" }
    public var expandTitle: String { expanded ? "Collapse" : "Expand" }
    public var expandTooltip: String { "\(expandTitle) (\u{2303}⌘F)" }
    public var expandIcon: Icon { expanded ? .collapse : .expand }
}

/// An entry of the header's ⋯ menu; `children` makes a submenu (Open With ▸).
public struct ZeusViewerMenuItem: Identifiable {
    public var id: String
    public var title: String
    public var isEnabled: Bool
    public var children: [ZeusViewerMenuItem]?
    public var action: () -> Void

    public init(_ title: String, id: String? = nil, isEnabled: Bool = true, children: [ZeusViewerMenuItem]? = nil,
                action: @escaping () -> Void = {}) {
        self.id = id ?? title
        self.title = title
        self.isEnabled = isEnabled
        self.children = children
        self.action = action
    }
}

/// The viewer's two header rows (§21.3): actions, then the title. Put a `ZeusViewerContextLine` under it.
public struct ZeusViewerHeader: View {
    public enum StepDirection: Sendable { case previous, next }

    public var model: ZeusViewerHeaderModel
    /// The default app's icon, 12 pt, before "Open in …"; nil shows the words alone.
    public var appIcon: Image?
    public var menu: [ZeusViewerMenuItem]
    public var onBack: () -> Void
    public var onOpen: () -> Void
    public var onReveal: () -> Void
    public var onExpand: () -> Void
    public var onStep: (StepDirection) -> Void
    @Environment(\.zeusPalette) private var palette

    /// Row height, matching the status strip.
    public static let rowHeight: CGFloat = 24

    public init(_ model: ZeusViewerHeaderModel, appIcon: Image? = nil, menu: [ZeusViewerMenuItem] = [],
                onBack: @escaping () -> Void, onOpen: @escaping () -> Void, onReveal: @escaping () -> Void,
                onExpand: @escaping () -> Void, onStep: @escaping (StepDirection) -> Void = { _ in }) {
        self.model = model
        self.appIcon = appIcon
        self.menu = menu
        self.onBack = onBack
        self.onOpen = onOpen
        self.onReveal = onReveal
        self.onExpand = onExpand
        self.onStep = onStep
    }

    public var body: some View {
        VStack(spacing: 0) {
            actions.frame(minHeight: Self.rowHeight)
            titleRow.frame(minHeight: Self.rowHeight)
        }
        .padding(.horizontal, ZeusTheme.Spacing.m)
        .background(palette.panel)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Document header")
    }

    private var actions: some View {
        HStack(spacing: ZeusTheme.Spacing.xxs) {
            ViewerLink(accessibility: "Back to \(model.backTitle)", action: onBack) {
                HStack(spacing: ZeusTheme.Spacing.xs) {
                    ZeusGlyph(.left).foregroundStyle(palette.title)
                    Text(model.backTitle).zeusFont(.caption).foregroundStyle(palette.title).lineLimit(1)
                }
            }
            .help("\(model.backTitle) (⌘[)")
            Spacer(minLength: ZeusTheme.Spacing.s)
            ViewThatFits(in: .horizontal) {
                openButton(words: true)
                openButton(words: false)
            }
            if model.canReveal {
                ViewerIconButton(label: ZeusViewerHeaderModel.revealTitle, action: onReveal) { active in
                    Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(active ? palette.title : palette.secondaryText)
                }
                .help(ZeusViewerHeaderModel.revealTooltip)
            }
            Menu {
                ForEach(menu) { item in MenuEntry(item: item) }
            } label: {
                ZeusGlyph(.more).foregroundStyle(palette.secondaryText).frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help(ZeusViewerHeaderModel.moreTitle)
            .accessibilityLabel(ZeusViewerHeaderModel.moreTitle)
            ViewerIconButton(label: model.expandTitle, action: onExpand) { active in
                ZeusGlyph.GlyphShape(rows: model.expandIcon.rows, pixel: 1)
                    .fill(active ? palette.title : palette.secondaryText)
                    .frame(width: 12, height: 12)
            }
            .help(model.expandTooltip)
        }
    }

    private func openButton(words: Bool) -> some View {
        Button(action: onOpen) {
            HStack(spacing: ZeusTheme.Spacing.xs) {
                if let appIcon { appIcon.resizable().interpolation(.none).frame(width: 12, height: 12) }
                if words || appIcon == nil { Text(model.openTitle) }
            }
        }
        .buttonStyle(ZeusButtonStyle(.secondary, size: .small))
        .help(model.openTooltip)
        .accessibilityLabel(model.openTitle)
    }

    /// One menu entry; `children` make a one-level submenu (Open With ▸).
    private struct MenuEntry: View {
        let item: ZeusViewerMenuItem
        var body: some View {
            if let children = item.children {
                Menu(item.title) {
                    ForEach(children) { child in Button(child.title, action: child.action).disabled(!child.isEnabled) }
                }
                .disabled(!item.isEnabled)
            } else {
                Button(item.title, action: item.action).disabled(!item.isEnabled)
            }
        }
    }

    private var titleRow: some View {
        HStack(spacing: ZeusTheme.Spacing.xs) {
            Text(model.title).zeusFont(.body).foregroundStyle(palette.text).lineLimit(1).truncationMode(.middle)
                .layoutPriority(1)
            if let location = model.location {
                Text("·").zeusFont(.caption).foregroundStyle(palette.secondaryText)
                Text(location).zeusFont(.caption).foregroundStyle(palette.secondaryText).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if let step = model.step {
                ViewerIconButton(label: "Previous attachment", action: { onStep(.previous) }) { active in
                    ZeusGlyph(.left).foregroundStyle(active ? palette.title : palette.secondaryText)
                }
                .disabled(!step.hasPrevious).opacity(step.hasPrevious ? 1 : 0.5)
                .help(ZeusViewerHeaderModel.previousTooltip)
                Text(step.text).zeusFont(.caption).foregroundStyle(palette.secondaryText).monospacedDigit()
                    .accessibilityLabel("Attachment \(step.index) of \(step.count)")
                ViewerIconButton(label: "Next attachment", action: { onStep(.next) }) { active in
                    ZeusGlyph(.right).foregroundStyle(active ? palette.title : palette.secondaryText)
                }
                .disabled(!step.hasNext).opacity(step.hasNext ? 1 : 0.5)
                .help(ZeusViewerHeaderModel.nextTooltip)
            }
        }
    }
}

/// A plain text button with a 22-pt target and the strip's 1-px focus underline (§15.1).
struct ViewerLink<Label: View>: View {
    let accessibility: String
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @FocusState private var focused: Bool
    @Environment(\.zeusPalette) private var palette
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        SwiftUI.Button(action: action) {
            label()
                .overlay(alignment: .bottom) {
                    Rectangle().fill(focused ? palette.focusRing : .clear).frame(height: ZeusTheme.pixel).offset(y: ZeusTheme.pixel)
                }
                .frame(minHeight: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .focusable(enabled, interactions: .edit).focusEffectDisabled().focused($focused)
        .onKeyPress(keys: [.space, .return]) { press in
            guard enabled, press.modifiers.intersection([.command, .option, .control]).isEmpty else { return .ignored }
            action(); return .handled
        }
        .accessibilityLabel(accessibility)
    }
}

/// An icon in a 22-pt target: secondary text at rest, the title colour on hover or focus, a 1-px focus ring.
struct ViewerIconButton<Icon: View>: View {
    let label: String
    let action: () -> Void
    @ViewBuilder let icon: (Bool) -> Icon
    @State private var hovering = false
    @FocusState private var focused: Bool
    @Environment(\.zeusPalette) private var palette
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        SwiftUI.Button(action: action) {
            icon((hovering || focused) && enabled)
                .frame(width: 22, height: 22)
                .overlay(Rectangle().strokeBorder(focused ? palette.focusRing : .clear, lineWidth: ZeusTheme.pixel))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .focusable(enabled, interactions: .edit).focusEffectDisabled().focused($focused)
        .onKeyPress(keys: [.space, .return]) { press in
            guard enabled, press.modifiers.intersection([.command, .option, .control]).isEmpty else { return .ignored }
            action(); return .handled
        }
        .onHover { hovering = $0 }
        .accessibilityLabel(label)
    }
}

// MARK: - Context line

/// The slim line under the header (§21.3, row 3): where the document came from, as one button that goes back
/// there, with the live "Updated" mark or a PDF page indicator at its trailing end. Ends in the 1-px divider.
public struct ZeusViewerContextLine: View {
    /// Where the document came from; the text is the message's takeaway, the folder's name or the linking document's name.
    public enum Origin: Equatable, Sendable {
        case message(String), folder(String), link(String)

        var prefix: String {
            switch self {
            case .message: "From: "
            case .folder: "In: "
            case .link: "Linked from: "
            }
        }
        var text: String {
            switch self {
            case .message(let text), .folder(let text), .link(let text): text
            }
        }
        var spoken: String {
            switch self {
            case .message(let text): "From the message: \(text)"
            case .folder(let text): "In the folder \(text)"
            case .link(let text): "Linked from \(text)"
            }
        }
    }

    public var origin: Origin
    /// Shown at the trailing end when there is no fresh update: "Page 3 of 12".
    public var trailing: String?
    /// Increment it when the file changes; the line shows "Updated" for two seconds.
    public var updateToken: Int
    public var action: () -> Void
    @State private var showingUpdated = false
    @Environment(\.zeusPalette) private var palette

    public static let updatedText = "Updated"
    public static let updatedDuration: TimeInterval = 2
    public static let fadeDuration: TimeInterval = 0.3
    /// Row height (`.caption` on one line plus padding).
    public static let height: CGFloat = 20

    public init(_ origin: Origin, trailing: String? = nil, updateToken: Int = 0, action: @escaping () -> Void) {
        self.origin = origin
        self.trailing = trailing
        self.updateToken = updateToken
        self.action = action
    }

    /// "Page 3 of 12".
    nonisolated public static func pageText(_ page: Int, of count: Int) -> String { "Page \(page) of \(count)" }

    public var body: some View {
        HStack(spacing: ZeusTheme.Spacing.s) {
            ViewerLink(accessibility: origin.spoken, action: action) {
                HStack(spacing: 0) {
                    Text(origin.prefix).zeusFont(.caption).foregroundStyle(palette.secondaryText)
                    Text(origin.text).zeusFont(.caption).foregroundStyle(palette.text).lineLimit(1).truncationMode(.tail)
                }
            }
            .help("Go to this message")
            Spacer(minLength: 0)
            if showingUpdated {
                Text(Self.updatedText).zeusFont(.caption).foregroundStyle(palette.positive)
                    .transition(.opacity.animation(.easeOut(duration: Self.fadeDuration)))
                    .accessibilityLabel("Document updated")
            } else if let trailing {
                Text(trailing).zeusFont(.caption).foregroundStyle(palette.secondaryText).monospacedDigit()
            }
        }
        .padding(.horizontal, ZeusTheme.Spacing.m)
        .frame(minHeight: Self.height)
        .background(palette.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.divider).frame(height: 1) }
        .task(id: updateToken) {
            guard updateToken > 0 else { return }
            withAnimation(.easeOut(duration: Self.fadeDuration)) { showingUpdated = true }
            try? await Task.sleep(for: .seconds(Self.updatedDuration))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: Self.fadeDuration)) { showingUpdated = false }
        }
    }
}

// MARK: - States

/// The centered state of the content area (§21.7): icon, name, a detail line, the message and small buttons.
/// As a `footer` it sits under the shown part of a too-large file, without the icon and name.
public struct ZeusViewerStatus: View {
    public struct Action: Identifiable {
        public var id: String { title }
        public var title: String
        public var style: CardOption.Style
        public var action: () -> Void

        public init(_ title: String, style: CardOption.Style = .secondary, action: @escaping () -> Void) {
            self.title = title
            self.style = style
            self.action = action
        }
    }

    /// Every message the viewer shows (§21.7), so tests and the app read one source.
    public enum Copy {
        public static let unsupported = "No preview for this kind of file."
        public static let missing = "Not found. Zeus will show the folder it was in."
        public static let unreadable = "Zeus can't read this file."
        public static let unreadableFolder = "Zeus can't read this folder."
        public static let emptyFile = "This file is empty."
        public static let emptyFolder = "This folder is empty."
        public static let loading = "Loading…"
        public static let revealOnly = "Zeus shows apps and scripts in Finder instead of opening them."
        /// Text, code and Markdown files show this much and then the footer.
        public static let sizeLimit = 5_000_000
        public static let tooLarge = "Showing the first 5 MB."
        /// "Open in Keynote for the rest."
        nonisolated public static func openForRest(app: String?) -> String { "\(ZeusViewerHeaderModel.openTitle(app: app)) for the rest." }
        /// Milliseconds before "Loading…" shows, so a fast file never flashes it.
        public static let loadingDelay: TimeInterval = 0.15
        /// "Keynote · 1.2 MB · Modified Today 8:02", from whichever parts are known.
        nonisolated public static func detail(kind: String?, size: String?, modified: String?) -> String? {
            let parts = [kind, size, modified.map { "Modified \($0)" }].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
    }

    public var icon: Image?
    public var name: String?
    public var missing: Bool
    public var detail: String?
    public var message: String
    public var actions: [Action]
    public var footer: Bool
    @Environment(\.zeusPalette) private var palette

    /// - Parameters:
    ///   - icon: Finder's icon for the file (32 pt); nil draws `doc.fill` in the secondary colour.
    ///   - missing: draws the name in `mutedText`.
    ///   - footer: the compact form under a capped file: message and actions only.
    public init(icon: Image? = nil, name: String? = nil, missing: Bool = false, detail: String? = nil, message: String,
                actions: [Action] = [], footer: Bool = false) {
        self.icon = icon
        self.name = name
        self.missing = missing
        self.detail = detail
        self.message = message
        self.actions = actions
        self.footer = footer
    }

    public var body: some View {
        VStack(spacing: ZeusTheme.Spacing.s) {
            if !footer {
                Group {
                    if let icon { icon.resizable().interpolation(.none).frame(width: 32, height: 32) }
                    else { Image(systemName: "doc.fill").font(.system(size: 24)).foregroundStyle(palette.secondaryText) }
                }
                .accessibilityHidden(true)
                if let name {
                    Text(name).zeusFont(.body).foregroundStyle(missing ? palette.mutedText : palette.text)
                        .lineLimit(1).truncationMode(.middle)
                }
                if let detail {
                    Text(detail).zeusFont(.caption).foregroundStyle(palette.secondaryText).multilineTextAlignment(.center)
                }
            }
            Text(message).zeusFont(footer ? .caption : .body).foregroundStyle(footer ? palette.secondaryText : palette.text)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            if !actions.isEmpty {
                HStack(spacing: ZeusTheme.Spacing.s) {
                    ForEach(actions) { action in
                        Button(action.title, action: action.action)
                            .buttonStyle(ZeusButtonStyle(action.style, size: .small))
                            .accessibilityLabel(action.title)
                    }
                }
            }
        }
        .padding(ZeusTheme.Spacing.m)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel([name, message].compactMap { $0 }.joined(separator: ". "))
    }
}

// MARK: - Folder rows

/// One entry of a folder listing (§21.6): symbol, name, then the kind and modified date in two right-aligned
/// columns that drop one at a time when the row is narrow. The whole row is the button.
public struct ZeusFolderRow: View {
    public var name: String
    /// "Folder", or the type's description ("Markdown", "Keynote").
    public var kind: String
    /// Already formatted ("Today 8:02", "Yesterday", "12 Oct").
    public var modified: String
    /// `ZeusAttachmentRow.symbol(for:)`: `folder.fill` or `doc.fill`.
    public var symbol: String
    public var action: () -> Void
    @State private var hovering = false
    @FocusState private var focused: Bool
    @Environment(\.zeusPalette) private var palette

    /// Width of each trailing column.
    public static let columnWidth: CGFloat = 88
    /// Rows shown before "and N more · Show in Finder".
    public static let limit = 500
    public static let folderKind = "Folder"

    public init(name: String, kind: String, modified: String, symbol: String, action: @escaping () -> Void) {
        self.name = name
        self.kind = kind
        self.modified = modified
        self.symbol = symbol
        self.action = action
    }

    /// "and 212 more · Show in Finder"
    nonisolated public static func moreCaption(_ count: Int) -> String {
        "and \(count) more · \(ZeusViewerHeaderModel.revealTitle)"
    }

    public var body: some View {
        let px = ZeusTheme.pixel
        Button(action: action) {
            // The name wins: a column is dropped before the name truncates (§21.6).
            ViewThatFits(in: .horizontal) {
                row(columns: [kind, modified], truncating: false)
                row(columns: [modified], truncating: false)
                row(columns: [], truncating: true)
            }
            .padding(.horizontal, ZeusTheme.Spacing.xs + px)
            .frame(minHeight: 22)
            .background(PixelFrame(outline: focused ? palette.focusRing : .clear, frame: nil,
                                   fill: hovering ? palette.field : .clear, steps: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .focusable(true, interactions: .edit).focusEffectDisabled().focused($focused)
        .onKeyPress(keys: [.space, .return]) { press in
            guard press.modifiers.intersection([.command, .option, .control]).isEmpty else { return .ignored }
            action(); return .handled
        }
        .onHover { hovering = $0 }
        .help("\(kind) · \(modified)")
        .accessibilityLabel("\(name), \(kind), modified \(modified)")
    }

    private func row(columns: [String], truncating: Bool) -> some View {
        HStack(spacing: ZeusTheme.Spacing.s) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hovering || focused ? palette.title : palette.secondaryText).frame(width: 14)
            Text(name).zeusFont(.body).foregroundStyle(palette.text).lineLimit(1).truncationMode(.middle)
                .fixedSize(horizontal: !truncating, vertical: false)
            Spacer(minLength: ZeusTheme.Spacing.s)
            ForEach(columns, id: \.self) { column($0) }
        }
    }

    private func column(_ text: String) -> some View {
        Text(text).zeusFont(.caption).foregroundStyle(palette.secondaryText).lineLimit(1).truncationMode(.tail)
            .frame(width: Self.columnWidth, alignment: .trailing)
    }
}

// MARK: - Find bar

/// The find bar under the header (§21.4): field, match count, previous/next, Done.
public struct ZeusFindBar: View {
    @Binding public var text: String
    /// 1-based index of the current match; ignored when `total` is nil or 0.
    public var current: Int
    /// Number of matches; nil before the first search (no count shown).
    public var total: Int?
    /// Bump it to put focus back in the field (⌘F while the bar is already open). The field is focused when the
    /// bar appears. Selecting the field's text is the app's (native) job.
    public var focusRequest: Int
    public var onPrevious: () -> Void
    public var onNext: () -> Void
    public var onDone: () -> Void
    @FocusState private var fieldFocused: Bool
    @Environment(\.zeusPalette) private var palette

    nonisolated public static let placeholder = "Find"
    nonisolated public static let doneTitle = "Done"
    nonisolated public static let noMatches = "No matches"
    public static let previousTooltip = "Previous (\u{21E7}Return)"   // system-font tooltip; see the header's note
    public static let nextTooltip = "Next (Return)"
    /// Match highlight: the accent at this opacity; the current match is the full accent with `onAccent` text.
    public static let highlightOpacity = 0.35

    public init(text: Binding<String>, current: Int, total: Int?, focusRequest: Int = 0, onPrevious: @escaping () -> Void,
                onNext: @escaping () -> Void, onDone: @escaping () -> Void) {
        self._text = text
        self.current = current
        self.total = total
        self.focusRequest = focusRequest
        self.onPrevious = onPrevious
        self.onNext = onNext
        self.onDone = onDone
    }

    /// "2 of 7", "No matches", or nil before a search.
    nonisolated public static func countText(current: Int, total: Int?) -> String? {
        guard let total else { return nil }
        return total == 0 ? noMatches : "\(current) of \(total)"
    }

    public var body: some View {
        let hasMatches = (total ?? 0) > 0
        HStack(spacing: ZeusTheme.Spacing.s) {
            ZeusTextField(Self.placeholder, text: $text).frame(maxWidth: 220)
                .focused($fieldFocused)
                .onKeyPress(keys: [.return]) { press in
                    guard hasMatches else { return .handled }
                    if press.modifiers.contains(.shift) { onPrevious() } else { onNext() }
                    return .handled
                }
                .onKeyPress(.escape) { onDone(); return .handled }
            if let count = Self.countText(current: current, total: total) {
                Text(count).zeusFont(.caption).foregroundStyle(palette.secondaryText).monospacedDigit().lineLimit(1)
                    .accessibilityLabel(count)
            }
            Spacer(minLength: 0)
            ViewerIconButton(label: "Previous match", action: onPrevious) { active in
                ZeusGlyph(.left).foregroundStyle(active ? palette.title : palette.secondaryText)
            }
            .disabled(!hasMatches).opacity(hasMatches ? 1 : 0.5).help(Self.previousTooltip)
            ViewerIconButton(label: "Next match", action: onNext) { active in
                ZeusGlyph(.right).foregroundStyle(active ? palette.title : palette.secondaryText)
            }
            .disabled(!hasMatches).opacity(hasMatches ? 1 : 0.5).help(Self.nextTooltip)
            ViewerLink(accessibility: Self.doneTitle, action: onDone) {
                Text(Self.doneTitle).zeusFont(.caption).foregroundStyle(palette.title)
            }
            .help("\(Self.doneTitle) (Esc)")
        }
        .padding(.horizontal, ZeusTheme.Spacing.m)
        .padding(.vertical, ZeusTheme.Spacing.xs)
        .background(palette.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.divider).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Find")
        .onAppear { fieldFocused = true }
        .onChange(of: focusRequest) { _, _ in fieldFocused = true }
    }
}
