import AppKit
import SwiftUI
import ZeusDesign

/// Independent scope controls: the same private list remains a hard stop in either mode.
struct ObservationLevelView: View {
    @Bindable var settings: ObservationSettings
    let level: Int
    var onChange: () -> Void = {}
    var hasPermission: () -> Bool = { true }
    @State private var showsConsent = false
    @State private var appError: String?
    @Environment(\.zeusPalette) private var palette
    private var policy: ObservationPolicy { settings.policy(level) }
    private var title: String { switch level { case 1: "App activity"; case 2: "Windows and documents"; case 3: "Screenshots"; default: "Typing" } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Level \(level) · \(title)").settingsTitle()
            if level > 2 {
                Text("Coming later. Off; Zeus doesn't capture \(level == 3 ? "screenshots" : "typing").").settingsCaption()
            } else {
                if level == 2 {
                    Toggle("Learn from windows and documents", isOn: Binding(get: { policy.enabled }, set: setEnabled))
                        .accessibilityLabel("Learn from windows and documents")
                    Text("Window titles, document paths and browser addresses, redacted on this Mac before storage. Safari: only the app name; details aren't kept because Zeus can't tell private windows apart.").settingsCaption()
                    if policy.enabled && !hasPermission() {
                        Text("Accessibility access is off. Zeus isn't recording window details.").settingsCaption()
                        KeyboardButton("Open Accessibility Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
                        }.accessibilityLabel("Open Accessibility Settings")
                    }
                }
                Picker("Where Zeus may learn", selection: binding(\.scope)) {
                    ForEach(ObservationPolicy.Scope.allCases, id: \.self) { scope in Text(scope.title).tag(scope) }
                }.accessibilityLabel("Level \(level): where Zeus may learn")
                Text(policy.scope == .chosenApps ? "Only the apps below. Your private list always wins." : "The apps below and your shared private list are excluded.").settingsCaption()
                ForEach(policy.apps) { app in
                    HStack {
                        Text(app.name).settingsBody()
                        Spacer()
                        KeyboardButton("Remove") { edit { $0.apps.removeAll { $0.id == app.id } } }
                            .accessibilityLabel("Remove \(app.name) from level \(level)")
                    }
                }
                KeyboardButton("Add App…", action: pickApp).accessibilityLabel("Add app to level \(level)")
                if let appError { Text(appError).settingsError() }
                Picker("Keep for", selection: binding(\.retentionDays)) {
                    ForEach([7, 14, 30, 60, 90], id: \.self) { Text("\($0) days").tag($0) }
                }.accessibilityLabel("Level \(level) retention")
            }
        }
        .sheet(isPresented: $showsConsent) {
            ObservationConsentSheet(enable: {
                edit { $0.consented = true; $0.enabled = true }
                showsConsent = false
            }, cancel: { showsConsent = false })
        }
    }
    private func binding<T>(_ key: WritableKeyPath<ObservationPolicy, T>) -> Binding<T> {
        Binding(get: { policy[keyPath: key] }, set: { value in edit { $0[keyPath: key] = value } })
    }
    private func edit(_ body: (inout ObservationPolicy) -> Void) { settings.edit(level, body); onChange() }
    private func setEnabled(_ enabled: Bool) {
        if enabled && !policy.consented { showsConsent = true } else { edit { $0.enabled = enabled } }
    }
    private func pickApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]; panel.allowsMultipleSelection = false
        panel.prompt = "Add"; panel.message = "Choose an app for this level."
        panel.begin { response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url, let app = PrivacySettingsView.excludedApp(at: url), !app.bundleIDs.isEmpty else { return }
                guard !policy.apps.contains(where: { $0.id == app.id }) else { appError = "\(app.name) is already listed."; return }
                appError = nil; edit { $0.apps.append(app) }
            }
        }
    }
}

struct ObservationConsentSheet: View {
    let enable: @MainActor @Sendable () -> Void
    let cancel: @MainActor @Sendable () -> Void
    @FocusState private var cancelFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Learn from windows and documents?").settingsTitle()
            Text("Zeus records the current window title, document path, Chrome address or selected Mail subject in apps you allow. Nothing you type or any page contents.").settingsBody()
            Text("Example kept on this Mac").settingsHeading()
            Text("Xcode · Window: Review for ‹email›\nDocument: file:///project/Example.swift").settingsBody().textSelection(.enabled)
            Text("Private apps, private browser windows, password entry and a locked Mac are excluded. Safari details aren't kept: Zeus can't tell its private windows apart.").settingsCaption()
            Text("Redaction happens on this Mac before storage. Summaries go to your assistant, which sends them to its model provider like any message. You can review and delete what Zeus kept in Privacy.").settingsCaption()
            Text("macOS Accessibility access is needed. Browser addresses and Mail subjects may also require Automation access.").settingsCaption()
            HStack {
                Spacer()
                KeyboardButton("Not Now", focus: $cancelFocused, action: cancel).keyboardShortcut(.cancelAction).accessibilityLabel("Not Now")
                KeyboardButton("Turn On", action: enable).buttonStyle(ZeusButtonStyle(.primary, size: .small)).accessibilityLabel("Turn On")
            }
        }.padding(24).frame(width: 480).environment(\.zeusFontChoice, .system)
            .onAppear { cancelFocused = true }
    }
}
