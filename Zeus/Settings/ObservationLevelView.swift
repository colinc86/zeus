import AppKit
import ApplicationServices
import SwiftUI
import ZeusDesign

struct ObservationLevelView: View {
    @Bindable var settings: ObservationSettings
    @Bindable var privacy: LearnSettings
    var onChange: @MainActor @Sendable () -> Void = {}
    var hasPermission: () -> Bool = { true }
    var requestPermission: () -> Void = {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
    @State private var showsConsent = false
    @State private var requestedPermission = false
    private var policy: ObservationPolicy { settings.policy(2) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Windows and pages").settingsTitle()
            Toggle("Let Zeus keep window titles and web addresses", isOn: Binding(get: { policy.enabled }, set: setEnabled))
                .accessibilityLabel("Let Zeus keep window titles and web addresses")
            Text("Zeus keeps the title of the window in front, the file it shows, and the address of the web page, so your assistant knows what you were working on. Never what's inside the window.").settingsCaption()
            if policy.enabled && !hasPermission() {
                Text(requestedPermission ? "Waiting for Accessibility permission." : "Accessibility is off for Zeus, so window titles aren't kept.").settingsCaption()
                KeyboardButton("Open System Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
                }.accessibilityLabel("Open Accessibility settings")
            }
            VStack(alignment: .leading, spacing: 12) {
                ObservationScopeView(settings: settings, privacy: privacy, level: 2, onChange: onChange)
                SettingsSegments(label: "Keep for", options: [7, 30, 90].map { ($0, "\($0) days") },
                    selection: Binding(get: { policy.retentionDays }, set: { value in edit { $0.retentionDays = value } }))
            }.disabled(!policy.enabled)
        }
        .sheet(isPresented: $showsConsent) {
            ObservationConsentSheet(enable: {
                edit { $0.consented = true; $0.enabled = true }; showsConsent = false
                requestedPermission = true; requestPermission()
            }, cancel: { showsConsent = false })
        }
    }
    private func edit(_ body: (inout ObservationPolicy) -> Void) { settings.edit(2, body); onChange() }
    private func setEnabled(_ enabled: Bool) {
        if enabled && !policy.consented { showsConsent = true } else { edit { $0.enabled = enabled } }
    }
}

struct ObservationScopeView: View {
    @Bindable var settings: ObservationSettings
    @Bindable var privacy: LearnSettings
    let level: Int
    var onChange: @MainActor @Sendable () -> Void = {}
    @State private var appResult: String?
    private var policy: ObservationPolicy { settings.policy(level) }
    private var apps: [ExcludedApp] { policy.scope == .exceptPrivate ? (level == 1 ? privacy.excludedApps : []) : policy.apps }
    static func scopeCaption(level: Int, scope: ObservationPolicy.Scope) -> String {
        if scope == .chosenApps { return "Zeus records this level only in these apps." }
        return level == 1 ? "Apps on your private list are never recorded at any level. Time in them counts only as private." : "Apps on your private list (above) are never recorded at any level."
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSegments(label: "Record in", options: ObservationPolicy.Scope.allCases.map { ($0, $0.title) },
                selection: Binding(get: { policy.scope }, set: { scope in settings.edit(level) { $0.scope = scope }; onChange() }))
            Text(Self.scopeCaption(level: level, scope: policy.scope)).settingsCaption()
            if apps.isEmpty && policy.scope == .chosenApps { Text("No apps chosen yet, so nothing is recorded at this level.").settingsCaption() }
            ForEach(apps) { app in
                appRow(app, sharedPrivate: false)
                if level >= 2 && policy.scope == .chosenApps && app.matches(bundleID: "com.apple.Safari", name: nil) {
                    Text(level == 3 ? "Private windows can't be told apart, so their pictures and descriptions are kept too." : "Private windows can't be told apart, so their titles and addresses are kept too.").settingsCaption().padding(.leading, 24)
                }
            }
            if level == 1 || policy.scope == .chosenApps {
                KeyboardButton("Add App…", action: pickApp).accessibilityLabel("Add app to level \(level)")
            }
            if level == 1 && policy.scope == .chosenApps {
                Text("Private apps").settingsHeading().padding(.top, 8)
                Text("Never recorded at any level. Time in them counts only as private.").settingsCaption()
                ForEach(privacy.excludedApps) { app in appRow(app, sharedPrivate: true) }
                KeyboardButton("Add App…") { presentPicker(scope: .exceptPrivate) }.accessibilityLabel("Add private app")
            }
            if let appResult { Text(appResult).settingsCaption() }
        }
    }
    private func appRow(_ app: ExcludedApp, sharedPrivate: Bool) -> some View {
        HStack {
            if let id = app.bundleIDs.first, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 16, height: 16).accessibilityHidden(true)
            } else {
                Image(systemName: "app").font(.system(size: 13)).frame(width: 16, height: 16).accessibilityHidden(true)
            }
            Text(app.name).settingsBody(); Spacer()
            KeyboardButton("–") {
                if sharedPrivate { privacy.excludedApps.removeAll { $0.id == app.id }; onChange() }
                else { remove(app) }
            }.accessibilityLabel("Remove \(app.name)")
        }
    }
    private func remove(_ app: ExcludedApp) {
        if policy.scope == .exceptPrivate { privacy.excludedApps.removeAll { $0.id == app.id } }
        else { settings.edit(level) { $0.apps.removeAll { $0.id == app.id } } }
        onChange()
    }
    private func pickApp() { presentPicker(scope: policy.scope) }
    private func presentPicker(scope: ObservationPolicy.Scope) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.application]; panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = "Add"; panel.message = scope == .exceptPrivate ? "Choose an app to keep private." : "Choose an app Zeus may record."
        panel.begin { response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url, let app = PrivacySettingsView.excludedApp(at: url), !app.bundleIDs.isEmpty else { return }
                if scope == .exceptPrivate { appResult = PrivacySettingsView.addPrivateApp(at: url, to: privacy) }
                else if !policy.apps.contains(where: { $0.id == app.id }) {
                    settings.edit(level) { $0.apps.append(app) }; appResult = "Added \(app.name)."
                } else { appResult = "\(app.name) is already listed." }
                onChange()
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
            Text("Windows and pages").settingsTitle()
            Text("Zeus keeps the title of the window in front, the file it shows and the web address, so your assistant can tell what you were working on and help at the right moment.").settingsBody()
            list("Zeus keeps", ["The title of the window in front, when it changes", "The file a document window shows", "The web address in Chrome and Edge", "The subject of the Mail message you're reading"])
            list("Zeus never keeps", ["What's inside a window: text, pictures, messages", "Anything while a password field is active", "Private windows in Chrome and Edge", "Apps on your private list"])
            Text("An example of what's stored").settingsHeading()
            ZeusFieldChrome {
                Text("09:41  Mail     Subject: Lunch with ‹name› on Friday\n09:44  Chrome   Q3 planning – Docs · docs.example.com/d/‹id›\n09:52  Xcode    ManagedSessionController.swift — Zeus")
                    .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
            }
            Text("Names, emails, numbers and other private details become placeholders like ‹name› before anything is stored.").settingsCaption()
            Text("Safari: Zeus keeps only that you used it. To keep its titles and web addresses too, add Safari under Only in apps I choose. Zeus can't tell Safari's private windows apart, so those would be kept too.").settingsCaption()
            Text("The records go into your assistant's folder, and summaries of them go to your assistant like any message. Where that goes depends on the assistant you chose.").settingsCaption()
            Text("Next, macOS asks you to allow Zeus under Accessibility. Zeus uses it only to read window titles.").settingsCaption()
            HStack {
                Spacer()
                KeyboardButton("Not Now", focus: $cancelFocused, action: cancel).keyboardShortcut(.cancelAction).accessibilityLabel("Not Now")
                KeyboardButton("Continue", action: enable).buttonStyle(ZeusButtonStyle(.primary, size: .small)).accessibilityLabel("Continue")
            }
        }.padding(24).frame(width: 480).environment(\.zeusFontChoice, .system)
            .onAppear { cancelFocused = true }
    }
    private func list(_ title: String, _ rows: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).settingsHeading()
            ForEach(rows, id: \.self) { Text("· " + $0).settingsBody() }
        }
    }
}
