import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ZeusDesign

struct TypingPrivacyView: View {
    @Bindable var model: TypingPrivacyModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Typing").settingsTitle()
            Toggle("Let Zeus keep what I type in apps I choose", isOn: Binding(get: { model.policy.enabled }, set: model.setEnabled))
                .accessibilityLabel("Let Zeus keep what I type in apps I choose")
                .disabled(!model.modelAvailable && !model.policy.enabled)
            Text("Zeus notes what you were typing about, like \"replying to a doctor about rescheduling\", so your assistant can help with it. Only in the apps you choose, and never in password fields.").settingsCaption()
            if let caption = model.statusCaption, model.policy.enabled || !model.modelAvailable {
                Text(caption).settingsCaption()
                if model.modelAvailable && model.permission == .reopenRequired {
                    KeyboardButton("Reopen Zeus") { model.reopen() }.accessibilityLabel("Reopen Zeus to start noting typing")
                } else if model.modelAvailable && [.notRequested, .waiting, .denied, .revoked].contains(model.permission) {
                    KeyboardButton("Open System Settings") { model.openPermissionSettings() }.accessibilityLabel("Open Input Monitoring settings")
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text("Record in").settingsBody(); Text("Only in apps I choose").settingsCaption() }
                if model.policy.apps.isEmpty { Text("No apps chosen yet, so nothing is recorded.").settingsCaption() }
                ForEach(model.policy.apps) { app in
                    HStack(spacing: 8) {
                        if let id = app.bundleIDs.first, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 16, height: 16).accessibilityHidden(true)
                        } else { Image(systemName: "app").frame(width: 16, height: 16).accessibilityHidden(true) }
                        Text(app.name).settingsBody(); Spacer()
                        KeyboardButton("–") { model.policies.edit(4) { $0.apps.removeAll { $0.id == app.id } }; model.changed() }
                            .accessibilityLabel("Remove \(app.name) from typing apps")
                    }
                    if app.matches(bundleID: "com.apple.Safari", name: nil) {
                        Text("Typing in Safari's private windows can't be told apart, so it's kept too.").settingsCaption().padding(.leading, 24)
                    }
                }
                KeyboardButton("Add App…") { chooseApps(firstUse: false) }.accessibilityLabel("Add app to level 4")
                Text("Zeus never records typing in an app you haven't added.").settingsCaption()
                Text("Apps on your private list (above) are never recorded at any level.").settingsCaption()
                if let result = model.appResult { Text(result).settingsCaption() }
                SettingsSegments(label: "Keep topics", options: [7, 30, 90].map { ($0, "\($0) days") },
                    selection: Binding(get: { model.policy.retentionDays }, set: model.setTopics))
                SettingsSegments(label: "Keep the words", options: [(0, "Don't keep"), (24, "24 hours"), (168, "7 days")],
                    selection: Binding(get: { model.policies.typingWordsHours }, set: model.setWords))
                Text(model.keepCaption).settingsCaption()
            }.disabled(!model.policy.enabled)
        }
        .sheet(isPresented: $model.showsConsent, onDismiss: {
            if model.needsAppPicker { chooseApps(firstUse: true) }
        }) { TypingConsentSheet(enable: { model.continueConsent() }, cancel: { model.cancelConsent() }) }
    }
    private func chooseApps(firstUse: Bool) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.application]; panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = "Add"; panel.message = "Choose the apps where Zeus may note what you type."
        panel.begin { response in MainActor.assumeIsolated {
            if response == .OK { for url in panel.urls { if let app = PrivacySettingsView.excludedApp(at: url) { model.addApp(app) } } }
            if firstUse { model.completeAppSelection() }
        } }
    }
}

struct TypingConsentSheet: View {
    let enable: @MainActor @Sendable () -> Void
    let cancel: @MainActor @Sendable () -> Void
    var heightLimit: CGFloat? = nil
    @FocusState private var cancelFocused: Bool
    private var maximumHeight: CGFloat { max(420, heightLimit ?? ((NSScreen.main?.visibleFrame.height ?? 1080) - 48)) }
    var body: some View {
        ViewThatFits(in: .vertical) {
            VStack(alignment: .leading, spacing: 16) { Text("Typing").settingsTitle(); content; footer }
                .padding(24).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 16) {
                Text("Typing").settingsTitle(); ScrollView { content }.scrollBounceBehavior(.basedOnSize); footer
            }.padding(24)
        }.frame(width: 540).frame(maxHeight: maximumHeight).fixedSize(horizontal: false, vertical: true)
            .environment(\.zeusFontChoice, .system).environment(\.zeusFontScale, .default).onAppear { cancelFocused = true }
    }
    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Zeus notes what you were typing about in the apps you choose, so your assistant knows what you're working on and can help with it. Before anything is kept, Zeus removes names, numbers, addresses and secrets, here on this Mac.").settingsBody()
            list("Zeus keeps", ["What each stretch of typing was about, for 30 days (you can change this)", "The words, with private details removed, for 24 hours (you can change this, or keep no words at all)"])
            list("Zeus never keeps", ["Anything you type into a password field", "Typing in apps you haven't chosen, or in private windows in Chrome and Edge", "What you paste: Zeus only notes that you pasted", "Typing made by other apps, such as a password manager filling in a form"])
            Text("An example").settingsHeading()
            ZeusFieldChrome {
                VStack(alignment: .leading, spacing: 6) {
                    Text("14:05  Mail  hi dr ‹name› can we move thursday to 3pm my ‹health› is still sore")
                        .font(.system(size: 11, design: .monospaced))
                    Text("→ Replying to a doctor about rescheduling an appointment").settingsBody()
                }
            }
            Text("The first line is the words as kept for 24 hours. The second is the topic kept for 30 days. Your assistant can read both while they're kept.").settingsCaption()
            Text("If you'd rather keep no words, choose Don't keep after turning this on. Topics still work.").settingsCaption()
            Text("Safari: Zeus notes nothing you type in Safari unless you add it under Only in apps I choose. Zeus can't tell Safari's private windows apart, so typing in those would be kept too.").settingsCaption()
        }
    }
    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Topics and the words, as kept, go into your assistant's folder, and topics into summaries. Where that goes depends on the assistant you chose.").settingsCaption()
            Text("Next, macOS asks you to allow Zeus under Input Monitoring. Zeus uses it only to read keys in the apps you choose.").settingsCaption()
            HStack {
                Spacer()
                KeyboardButton("Not Now", focus: $cancelFocused, action: cancel).keyboardShortcut(.cancelAction).accessibilityLabel("Not Now")
                KeyboardButton("Continue", action: enable).buttonStyle(ZeusButtonStyle(.primary, size: .small)).accessibilityLabel("Continue")
            }
        }
    }
    private func list(_ title: String, _ rows: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).settingsHeading()
            ForEach(rows, id: \.self) { Text("· " + $0).settingsBody() }
        }
    }
}
