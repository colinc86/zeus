import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ZeusDesign

/// A resizable local viewer. It never starts observation and never requests agent data.
struct JournalWindowView: View {
    @Bindable var model: JournalViewerModel
    var settings: AppSettings?
    var body: some View { rootBody.environment(\.zeusTheme, settings?.currentTheme ?? .classic).zeusThemeAppearance(settings?.currentTheme ?? .classic) }
    private var rootBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSegments(label: "", options: [(false, "Kept on this Mac"), (true, "Sent to your assistant")], selection: $model.sentOnly)
            HStack {
                KeyboardButton("‹") { step(-1) }.accessibilityLabel("Previous day")
                KeyboardButton(dayTitle) { model.day = Date() }.accessibilityLabel("Journal day: \(dayTitle); show today")
                KeyboardButton("›") { step(1) }.accessibilityLabel("Next day")
                if !model.sentOnly {
                    ZeusMenuPicker("Level", choices: [ZeusChoice(id: 1, title: "Apps and timing"), ZeusChoice(id: 2, title: "Windows and pages"), ZeusChoice(id: 3, title: "Screen"), ZeusChoice(id: 4, title: "Typing")],
                        selection: Binding<Int?>(get: { model.level == 0 ? nil : model.level }, set: { model.level = $0 ?? 0 }), noneTitle: "All levels")
                    ZeusMenuPicker("App", choices: model.applications.map { ZeusChoice(id: $0, title: JournalDisplay.appName($0)) },
                        selection: Binding<String?>(get: { model.app.isEmpty ? nil : model.app }, set: { model.app = $0 ?? "" }), noneTitle: "All apps")
                }
            }
            ZeusTextField("Search what Zeus kept", text: $model.search).accessibilityLabel("Search what Zeus kept")
            JournalViewerView(model: model).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.padding(20).frame(minWidth: 560, minHeight: 340)
            .environment(\.zeusFontChoice, .system)
            .buttonStyle(ZeusButtonStyle(.secondary, size: .small))
            .toggleStyle(ZeusCheckboxStyle())
    }
    private var dayTitle: String {
        if Calendar.current.isDateInToday(model.day) { return "Today" }
        if Calendar.current.isDateInYesterday(model.day) { return "Yesterday" }
        let formatter = DateFormatter(); formatter.dateFormat = "EEE d MMM"; return formatter.string(from: model.day)
    }
    private func step(_ days: Int) { if let day = Calendar.current.date(byAdding: .day, value: days, to: model.day) { model.day = day } }
}

struct JournalViewerView: View {
    @Bindable var model: JournalViewerModel
    @State private var pendingDelete: JournalDeletion?
    @State private var deleteTitle = ""
    @State private var exportError: String?
    @State private var expanded: Set<String> = []
    @FocusState private var cancelFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.sentOnly ? "Everything Zeus sent your assistant about you. Your assistant's model provider received these like any message." : "Exactly as stored on this Mac, with redactions visible.").settingsCaption()
            if model.items.isEmpty {
                Text(model.level == 0 && model.app.isEmpty && model.search.isEmpty ? "Nothing kept on this day." : "Nothing matches.").settingsCaption()
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(model.timeline) { row in
                if case .picture(let picture) = row {
                    JournalPictureRow(picture: picture, model: model.pictures)
                } else if case .typing(let group) = row {
                    JournalTypingGroupView(group: group, initiallyExpanded: Calendar.current.isDateInToday(model.day), search: model.search,
                        deleteRun: { model.deleteItem($0.item) })
                } else if case .record(let item) = row {
                JournalRecordRow(item: item, sent: model.sentOnly, expanded: expanded.contains(item.id), toggle: {
                    if !expanded.insert(item.id).inserted { expanded.remove(item.id) }
                }, delete: { model.deleteItem(item) })
                }
                SettingsDivider()
            }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                if model.deletedItem != nil {
                    Text("Deleted.").settingsCaption()
                    KeyboardButton("Undo") { model.undoDelete() }.accessibilityLabel("Undo journal deletion")
                }
                if model.pictures.deleted != nil {
                    Text("Deleted.").settingsCaption()
                    KeyboardButton("Undo") { model.pictures.undoDelete() }.accessibilityLabel("Undo picture deletion")
                }
                Spacer()
                if !model.sentOnly {
                    KeyboardButton("Delete This Day…") { requestDelete(.day(model.day), "Delete everything Zeus kept on \(model.day.formatted(date: .abbreviated, time: .omitted))? This can't be undone.") }
                        .accessibilityLabel("Delete this journal day")
                    if !model.app.isEmpty {
                        KeyboardButton("Delete \(JournalDisplay.appName(model.app))…") { requestDelete(.app(model.app), "Delete everything Zeus kept from \(JournalDisplay.appName(model.app)), on every day? This can't be undone.") }
                            .accessibilityLabel("Delete this app's journal")
                    }
                }
                KeyboardButton("Export…", action: export).accessibilityLabel("Export journal selection").disabled(model.items.isEmpty)
            }
            Text("Exports what's shown, as stored.").settingsCaption()
            if pendingDelete != nil {
                Text(deleteTitle).settingsBody()
                HStack {
                    KeyboardButton("Cancel", focus: $cancelFocused) { pendingDelete = nil }.keyboardShortcut(.cancelAction).accessibilityLabel("Cancel deletion")
                    KeyboardButton("Delete") { if let selection = pendingDelete, model.delete(selection) { pendingDelete = nil } }
                        .buttonStyle(ZeusButtonStyle(.destructive, size: .small)).accessibilityLabel("Confirm journal deletion")
                }.onAppear { cancelFocused = true }
            }
            if let error = model.error ?? model.pictures.error ?? exportError { Text(error).settingsError() }
        }
        .sheet(item: Binding(get: { model.pictures.selected }, set: { model.pictures.selectedID = $0?.id })) {
            _ in JournalPictureDetail(model: model.pictures)
        }
    }
    private func requestDelete(_ selection: JournalDeletion, _ title: String) { deleteTitle = title; pendingDelete = selection }
    private func export() {
        guard let data = model.export() else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = "Zeus Journal \(formatter.string(from: model.day)).json"
        panel.begin { response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url else { return }
                do { try data.write(to: url, options: .atomic); exportError = nil }
                catch { exportError = "Couldn't write the export. Choose another location." }
            }
        }
    }
}

/// Stored strings are shown verbatim; redaction placeholders have a distinct, quiet role.
struct JournalItemView: View {
    let item: JournalItem
    @Environment(\.zeusPalette) private var palette
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(item.time.formatted(date: .omitted, time: .shortened)) · \(JournalDisplay.name(item))").settingsCaption()
            if JournalDisplay.showsDescription(item) { stored(item.payload.value.description) }
            if item.level == .focus {
                if let text = item.payload.value.text { stored(text) }
                ForEach(JournalDisplay.detailLines(item), id: \.self) { stored($0) }
            }
            if item.payload.report.total > 0 { Text("\(item.payload.report.total) private details removed").settingsCaption() }
        }.fixedSize(horizontal: false, vertical: true)
    }
    private func stored(_ value: String) -> some View {
        Text(Self.styled(value, palette: palette)).zeusFont(.body).textSelection(.enabled)
    }
    static func styled(_ value: String, palette: ZeusPalette) -> AttributedString {
        var result = AttributedString(value); result.foregroundColor = palette.text
        if let regex = try? NSRegularExpression(pattern: "‹[^›]+›") {
            for match in regex.matches(in: value, range: NSRange(value.startIndex..., in: value)) {
                if let range = Range(match.range, in: value),
                   let lower = AttributedString.Index(range.lowerBound, within: result),
                   let upper = AttributedString.Index(range.upperBound, within: result) {
                    result[lower..<upper].foregroundColor = palette.secondaryText
                }
            }
        }
        return result
    }
    private var engine: String {
        switch item.payload.report.semanticEngine {
        case .onDeviceModel: "On-device model"
        case .naturalLanguage: "Patterns and name recognition"
        case .patternsOnly: "Patterns only"
        }
    }
}


@MainActor enum JournalDisplay {
    static func appName(_ id: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return id }
        return (FileManager.default.displayName(atPath: url.path) as NSString).deletingPathExtension
    }
    static func ledgerTitle(_ item: JournalItem) -> String {
        switch item.payload.value.details["kind"] {
        case "reflection": "Day reflection"
        case "digest": "Morning summary"
        case "moment": "Note"
        default: item.payload.value.description
        }
    }
    static func detailLines(_ item: JournalItem) -> [String] {
        guard item.level == .focus else { return [] }
        return item.payload.value.details.keys.sorted().compactMap { key in
            let title: String
            switch key { case "window", "title": title = "Window"; case "document": title = "Document"; case "address", "url": title = "Address"; default: return nil }
            guard let value = item.payload.value.details[key], !value.isEmpty else { return nil }
            return title + ": " + (key == "document" ? FocusRecord.documentCaption(value) : value)
        }
    }
    static func showsDescription(_ item: JournalItem) -> Bool { item.payload.value.description != name(item) }
    static func name(_ item: JournalItem) -> String {
        if item.kind == .activity && item.payload.value.details["kind"] == "private" { return "Private" }
        if let app = item.app { return appName(app) }
        return item.payload.value.details["kind"] == "private" ? "Private" : "Zeus"
    }
}

private struct JournalRecordRow: View {
    let item: JournalItem
    let sent: Bool
    let expanded: Bool
    let toggle: @MainActor @Sendable () -> Void
    let delete: @MainActor @Sendable () -> Void
    @State private var hovered = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if sent {
                KeyboardButton(action: toggle) {
                    HStack(spacing: 8) {
                        Text(expanded ? "\u{25BE}" : "\u{25B8}").settingsCaption()
                        Text(item.time.formatted(date: .omitted, time: .shortened)).settingsCaption()
                        Text(JournalDisplay.ledgerTitle(item)).settingsBody()
                        ZeusSessionLabel(item.payload.value.details["sessionLabel"] ?? item.payload.value.details["session"] ?? "Assistant",
                            colorIndex: ZeusSessionLabel.colorIndex(for: item.payload.value.details["sessionKey"] ?? item.payload.value.details["sessionLabel"] ?? "assistant"))
                        Spacer()
                        Text("\((item.payload.value.text ?? "").split(whereSeparator: \.isWhitespace).count) words").settingsCaption()
                    }
                }.buttonStyle(.plain).accessibilityLabel("Show exact sent text: \(item.payload.value.description)")
                    .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                if expanded {
                    ZeusFieldChrome { Text(item.payload.value.text ?? item.payload.value.description).settingsBody().textSelection(.enabled) }
                }
            } else {
                JournalItemView(item: item)
                    .padding(.trailing, 60)
                    .overlay(alignment: .topTrailing) {
                        if hovered { KeyboardButton("Delete", action: delete).accessibilityLabel("Delete journal item") }
                    }
            }
        }
        .contentShape(Rectangle()).onHover { hovered = $0 }
        .contextMenu { if !sent { Button("Delete", action: delete) } }
        .modifier(JournalDeleteAccessibility(enabled: !sent, delete: delete))
    }
}

private struct JournalDeleteAccessibility: ViewModifier {
    let enabled: Bool
    let delete: @MainActor @Sendable () -> Void
    @ViewBuilder func body(content: Content) -> some View {
        if enabled { content.accessibilityAction(named: Text("Delete"), delete) }
        else { content }
    }
}
