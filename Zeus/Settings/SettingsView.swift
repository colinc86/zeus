import SwiftUI
import Observation
import ZeusProtocol
import ZeusDesign

enum SettingsTab: String, CaseIterable {
    case general = "General", appearance = "Appearance", agent = "Assistant", character = "Character", privacy = "Privacy", about = "About"
    #if DEBUG
    case debug = "Debug"
    #endif
}

@MainActor
@Observable
final class SettingsNavigation { var tab = SettingsTab.general }

struct SettingsView: View {
    @Bindable var settings: AppSettings
    let managed: ManagedAssistantModel
    let cards: CardStore
    let status: AvatarStatusModel
    let messaging: any AgentMessaging
    let preview: AgentMessagingHub
    let testMessage: ComposeModel
    let injectDemo: (DemoCardKind) -> Void
    let resetPosition: () -> Void
    @Bindable var navigation: SettingsNavigation
    let login: LoginItemModel
    let hotKey: GlobalHotKey
    let activity: SurfaceActivity
    var updater: any AppUpdating = UpdaterService()
    /// Settings › Privacy's "Learn from me" (L1); nil shows the pane as unavailable.
    var learn: LearnFromMe?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    /// This root's own colors come from the theme directly: the environment it sets applies to its children.
    private var palette: ZeusPalette { settings.currentTheme.palette(for: colorScheme, contrast: colorSchemeContrast) }
    @State private var generalJump: GeneralSettingsSection?

    // T1: the selected theme reaches every view below through \.zeusTheme (and so \.zeusPalette).
    var body: some View { rootBody.environment(\.zeusTheme, settings.currentTheme) }

    @ViewBuilder private var rootBody: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsTabBar(navigation: navigation)
            Rectangle().fill(palette.fieldBorder).frame(height: ZeusTheme.pixel)
            ScrollViewReader { proxy in
                VStack(alignment: .leading, spacing: 16) {
                    if navigation.tab == .general {
                        GeneralSettingsJumpRow {
                            proxy.scrollTo($0, anchor: .top)
                            generalJump = $0
                        }
                    }
                    ScrollView {
                        content.frame(maxWidth: .infinity, alignment: .leading)
                            // One type system (D2-3): Zeus buttons, checkboxes, fields and body text unless a pane says otherwise.
                            .buttonStyle(ZeusButtonStyle(.secondary, size: .small))
                            .toggleStyle(ZeusCheckboxStyle())
                            .textFieldStyle(ZeusTextFieldStyle())
                            .settingsBody()
                    }
                }
                .onChange(of: managed.confirmation, initial: true) { revealManagedConfirmation(proxy) }
                .onChange(of: navigation.tab) { revealManagedConfirmation(proxy) }
            }
        }
        .padding(24)
        .frame(minWidth: SettingsWindowSize.minimum.width, maxWidth: .infinity,
               minHeight: SettingsWindowSize.minimum.height, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.zeusAnimationsActive, activity.settings)
        .environment(\.zeusFontChoice, .system)
        // UI scripting can query Settings without activating VoiceOver first.
        .environment(\.accessibilityEnabled, true)
    }

    private func revealManagedConfirmation(_ proxy: ScrollViewProxy) {
        guard navigation.tab == .agent, managed.confirmation == .newConversation else { return }
        Task { @MainActor in
            await Task.yield()
            guard navigation.tab == .agent, managed.confirmation == .newConversation else { return }
            proxy.scrollTo("newConversationConfirmation", anchor: .top)
        }
    }

    @ViewBuilder private var content: some View {
        switch navigation.tab {
        case .general:
            GeneralSettingsView(settings: settings, login: login, hotKey: hotKey, cards: cards, updater: updater,
                                focusRequest: generalJump)
        case .appearance:
            AppearanceSettingsView(settings: settings)
        case .agent:
            AssistantSettingsView(settings: settings, managed: managed, messaging: preview, testMessage: testMessage)
        case .character:
            CharacterSettingsView(settings: settings, resetPosition: resetPosition)
        case .privacy:
            if let learn { PrivacySettingsView(learn: learn) }
            else { Text("Learn from me isn't available here.").settingsCaption() }
        case .about:
            AboutSettingsView()
        #if DEBUG
        case .debug:
            VStack(alignment: .leading, spacing: 16) {
                Text("Messaging preview").zeusFont(.title)
                Toggle("Use preview sessions and simulated sends", isOn: Binding(get: { preview.previewEnabled }, set: { preview.previewEnabled = $0 })).accessibilityLabel("Use preview sessions and simulated sends")
                Picker("Preview result", selection: Binding(get: { preview.previewOutcome }, set: { preview.previewOutcome = $0 })) {
                    ForEach(AgentMessagingHub.PreviewOutcome.allCases) { outcome in Text(outcome.rawValue.capitalized).tag(outcome) }
                }.disabled(!preview.previewEnabled)
                Text("Preview sends stay in this app and never reach an agent.").settingsCaption()
                Picker("Assistant activity", selection: Binding(get: { preview.previewActivity }, set: { preview.previewActivity = $0 })) {
                    ForEach(AgentMessagingHub.PreviewActivity.allCases) { phase in Text(phase.rawValue.capitalized).tag(phase) }
                }.disabled(!preview.previewEnabled)
                if preview.previewActivity == .working {
                    ZeusTextField("Activity detail", text: Binding(get: { preview.previewActivityDetail }, set: { preview.previewActivityDetail = $0 }))
                    Toggle("Show progress", isOn: Binding(get: { preview.previewActivityProgress != nil }, set: { preview.previewActivityProgress = $0 ? 0.4 : nil })).accessibilityLabel("Show progress")
                    if preview.previewActivityProgress != nil {
                        Slider(value: Binding(get: { preview.previewActivityProgress ?? 0 }, set: { preview.previewActivityProgress = $0 }), in: 0...1)
                    }
                }
                SettingsDivider()
                Text("Demo cards").zeusFont(.title)
                ForEach(DemoCardKind.allCases) { kind in KeyboardButton(kind.rawValue) { injectDemo(kind) }.accessibilityLabel(kind.rawValue) }
                Text("Replies are recorded in card history. Delivery starts when the runtime is connected.")
                    .settingsCaption()
                if let last = cards.history.first(where: { $0.response != nil }) {
                    Text("Last reply: \(last.response?.summary ?? "")").settingsCaption()
                }
                SettingsDivider()
                Text("Avatar state").settingsHeading()
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110))]) {
                    ForEach(AvatarState.allCases, id: \.self) { state in
                        KeyboardButton(state.rawValue.capitalized) { status.setOverride(state, detail: "Debug preview", progress: state == .working ? 0.45 : nil, ttl: 600) }.accessibilityLabel(state.rawValue.capitalized)
                    }
                }
                KeyboardButton("Automatic state") { status.clearOverride() }.accessibilityLabel("Automatic state")
                Text("New cards take priority for 2.5 seconds.").settingsCaption()
                KeyboardButton(preview.previewDeliveryIssue == nil ? "Show preview delivery warning" : "Clear preview delivery warning") {
                    preview.previewDeliveryIssue = preview.previewDeliveryIssue == nil
                        ? DeliveryIssue(title: "Couldn't reach your assistant", detail: "2 replies couldn't reach Preview Claude (Zeus). They'll be sent automatically when it reconnects.", pendingCount: 2, since: Date().addingTimeInterval(-180)) : nil
                }.accessibilityLabel(preview.previewDeliveryIssue == nil ? "Show preview delivery warning" : "Clear preview delivery warning").disabled(!preview.previewEnabled)
                if let error = cards.persistenceError { Text(error).foregroundStyle(palette.destructive) }
            }
        #endif
        }
    }

}

/// Keeps the Settings navigation controls named independently of the selected pane.
struct SettingsTabBar: View {
    @Bindable var navigation: SettingsNavigation
    @State private var frames = SettingsTabFrames()
    var body: some View {
        // Whole labels when they fit (L1 made six tabs; equal widths cut "Appearance" at the minimum window width),
        // otherwise equal widths.
        ViewThatFits(in: .horizontal) {
            tabs(equalWidths: false)
            tabs(equalWidths: true)
        }
    }

    private func tabs(equalWidths: Bool) -> some View {
        HStack(spacing: ZeusTheme.Spacing.s) {
            ForEach(SettingsTab.allCases, id: \.self) { tab in
                KeyboardButton { navigation.tab = tab } label: {
                    if equalWidths { Text(tab.rawValue).frame(maxWidth: .infinity) }
                    else { Text(tab.rawValue).lineLimit(1).fixedSize().frame(maxWidth: .infinity) }
                }
                .buttonStyle(ZeusButtonStyle(navigation.tab == tab ? .primary : .secondary, size: .small))
                // A12b: SwiftUI publishes a button's name only as its AX description; System Events and other processes read
                // the AX title. An AppKit button as the accessibility representation carries both, and its selected value.
                .background(SettingsTabFrameReader(tab: tab, frames: frames))
                .accessibilityRepresentation {
                    SettingsTabAccessibility(tab: tab, isSelected: navigation.tab == tab, frames: frames) { navigation.tab = tab }
                }
            }
        }
    }
}

/// Where each Settings tab is on screen, for its accessibility stand-in (A12b).
@MainActor final class SettingsTabFrames {
    var views: [SettingsTab: NSView] = [:]
    func screenFrame(_ tab: SettingsTab) -> NSRect? {
        guard let view = views[tab], let window = view.window else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }
}

/// A zero-cost view behind each tab that registers itself, so the stand-in can report the tab's real frame.
private struct SettingsTabFrameReader: NSViewRepresentable {
    let tab: SettingsTab
    let frames: SettingsTabFrames
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.setAccessibilityElement(false)
        frames.views[tab] = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { frames.views[tab] = view }
}

/// The accessibility stand-in for one Settings tab (A12b). SwiftUI publishes a button's name only as its AX description;
/// System Events and other processes read the AX title (`name`). A native button cell carries the title, the
/// description, AX selected for the current tab, the tab's real on-screen frame, and press.
private struct SettingsTabAccessibility: NSViewRepresentable {
    let tab: SettingsTab
    let isSelected: Bool
    let frames: SettingsTabFrames
    let action: () -> Void

    final class Cell: NSButtonCell {
        var frameProvider: (() -> NSRect?)?
        var selected = false
        var press: (() -> Void)?
        var name = ""
        override func accessibilityTitle() -> String? { name }
        override func accessibilityLabel() -> String? { name }
        override func accessibilityFrame() -> NSRect { frameProvider?() ?? super.accessibilityFrame() }
        override func isAccessibilitySelected() -> Bool { selected }
        override func accessibilityPerformPress() -> Bool { press?(); return press != nil }
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(frame: .zero)
        button.cell = Cell(textCell: tab.rawValue)
        button.setButtonType(.momentaryPushIn)
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        button.title = tab.rawValue
        button.setAccessibilityLabel(tab.rawValue)
        guard let cell = button.cell as? Cell else { return }
        cell.name = tab.rawValue
        let frames = frames, tab = tab
        cell.frameProvider = { MainActor.assumeIsolated { frames.screenFrame(tab) } }
        cell.selected = isSelected
        cell.press = action
    }
}
