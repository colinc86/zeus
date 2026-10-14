import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ZeusDesign

/// Settings › Privacy (L1, CONTRACT §13): "Learn from me", what Zeus has recorded today, the notes it may send, private
/// apps, how long activity is kept, Pause for Today and Delete Everything.
struct PrivacySettingsView: View {
    let learn: LearnFromMe
    @Bindable var settings: LearnSettings
    @State private var showsIntro = false
    @State private var confirmingDelete = false
    @State private var choosingApp = false
    @FocusState private var cancelFocused: Bool
    @Environment(\.zeusPalette) private var palette

    /// Verbatim from CONTRACT §13.
    static let caveat = "Summaries go to your assistant, which sends them to its model provider like any message. Raw activity never leaves this Mac."
    static let scope = "Zeus notes which app is in front, app launches and quits, when you lock, sleep or step away, and how many displays you use. Never what you type, copy, read or open."

    init(learn: LearnFromMe) {
        self.learn = learn
        settings = learn.settings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Learn from me").settingsTitle()
            Toggle("Let Zeus learn when and in what I work", isOn: Binding(get: { settings.enabled }, set: switchChanged))
                .accessibilityLabel("Let Zeus learn when and in what I work")
                .disabled(!learn.isAvailable)
            Text(Self.scope).settingsCaption()
            Text(Self.caveat).settingsCaption()
            if settings.enabled { pauseRow }
            if let error = learn.writeError ?? learn.learnings?.saveError { Text(error).settingsError() }

            SettingsDivider()
            Text("What Zeus has recorded").settingsTitle()
            RecordedTodayList(events: learn.today)

            SettingsDivider()
            Text("Notes to your assistant").settingsTitle()
            Text("Each morning Zeus sends a short summary of the day before. It can also send up to four notes a day:").settingsCaption()
            ForEach(MomentKind.allCases) { kind in
                Toggle(kind.title, isOn: Binding(get: { settings.momentKinds.contains(kind) },
                                                 set: { if $0 { settings.momentKinds.insert(kind) } else { settings.momentKinds.remove(kind) } }))
                    .accessibilityLabel(kind.title)
            }

            SettingsDivider()
            Text("Private apps").settingsTitle()
            Text("Time in these apps is recorded as private: how long, never which app.").settingsCaption()
            VStack(alignment: .leading, spacing: ZeusTheme.Spacing.s) {
                ForEach(settings.excludedApps) { app in
                    HStack(spacing: ZeusTheme.Spacing.s) {
                        Text(app.name).settingsBody().lineLimit(1)
                        Spacer(minLength: 0)
                        Button("Remove") { settings.excludedApps.removeAll { $0 == app } }
                            .accessibilityLabel("Remove \(app.name)")
                    }
                }
            }
            Button("Add App…", action: chooseApp).accessibilityLabel("Add App…")

            SettingsDivider()
            SettingsSegments(label: "Keep activity for", options: LearnSettings.retentionChoices.map { ($0, "\($0) days") },
                             selection: $settings.retentionDays)
            Text("Summaries are kept for a year. Older activity is deleted every night.").settingsCaption()
            if confirmingDelete { deleteConfirmation } else {
                Button("Delete Everything…") { confirmingDelete = true }
                    .buttonStyle(ZeusButtonStyle(.destructive, size: .small))
                    .accessibilityLabel("Delete Everything…")
            }
        }
        .sheet(isPresented: $showsIntro) {
            LearnIntroSheet(turnOn: { settings.introShown = true; learn.setEnabled(true); showsIntro = false },
                            notNow: { showsIntro = false })
        }
        .onAppear { learn.refreshToday() }
    }

    @ViewBuilder private var pauseRow: some View {
        HStack(spacing: ZeusTheme.Spacing.s) {
            if learn.isPausedNow {
                Text("Paused until tomorrow.").settingsBody()
                Button("Resume") { learn.resume() }.accessibilityLabel("Resume")
            } else {
                Text("Recording.").settingsBody()
                Button("Pause for Today") { learn.pauseForToday() }.accessibilityLabel("Pause for Today")
            }
        }
    }

    private var deleteConfirmation: some View {
        VStack(alignment: .leading, spacing: ZeusTheme.Spacing.s) {
            Text("Delete all recorded activity and every summary? This can't be undone.")
                .zeusFont(.caption).foregroundStyle(palette.text).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: ZeusTheme.Spacing.s) {
                Button("Delete") { learn.deleteEverything(); confirmingDelete = false }
                    .buttonStyle(ZeusButtonStyle(.destructive, size: .small)).accessibilityLabel("Delete").focusable()
                Button("Cancel") { confirmingDelete = false }
                    .accessibilityLabel("Cancel").focusable().focused($cancelFocused)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(ZeusTheme.Spacing.s).background(palette.field)
        .onAppear { cancelFocused = true }
    }

    private func switchChanged(_ on: Bool) {
        if on && !settings.introShown { showsIntro = true } else { learn.setEnabled(on) }
    }

    private func chooseApp() {
        guard !choosingApp else { return }
        choosingApp = true
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = "Add"
        panel.message = "Choose an app to keep private."
        panel.begin { response in
            MainActor.assumeIsolated {
                choosingApp = false
                guard response == .OK, let url = panel.url, let app = Self.excludedApp(at: url) else { return }
                if !settings.excludedApps.contains(where: { $0.bundleIDs.contains(app.id) || $0.name == app.name }) {
                    settings.excludedApps.append(app)
                }
            }
        }
    }

    /// The app at `url` as a private-list entry, named as Finder shows it.
    static func excludedApp(at url: URL) -> ExcludedApp? {
        let name = (FileManager.default.displayName(atPath: url.path) as NSString).deletingPathExtension
        let bundleID = Bundle(url: url)?.bundleIdentifier
        guard !name.isEmpty else { return nil }
        return ExcludedApp(name: name, bundleIDs: bundleID.map { [$0] } ?? [])
    }
}

/// Today's raw events in plain words, newest first, in a short scrolling field.
private struct RecordedTodayList: View {
    let events: [ActivityEvent]
    @Environment(\.zeusPalette) private var palette
    static let shown = 200

    var body: some View {
        VStack(alignment: .leading, spacing: ZeusTheme.Spacing.s) {
            if events.isEmpty {
                Text("Nothing yet today.").settingsCaption()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(events.suffix(Self.shown).reversed().enumerated()), id: \.offset) { _, event in
                            HStack(alignment: .firstTextBaseline, spacing: ZeusTheme.Spacing.s) {
                                Text(LearningSummarizer.clock(event.t, .current)).foregroundStyle(palette.secondaryText)
                                Text(event.plainDescription).foregroundStyle(palette.text)
                            }
                            .zeusFont(.caption)
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .padding(ZeusTheme.Spacing.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 140)
                .background(palette.field)
                .overlay(Rectangle().strokeBorder(palette.fieldBorder, lineWidth: ZeusTheme.pixel))
                Text(events.count > Self.shown ? "Today, newest first: the latest \(Self.shown) of \(events.count)."
                                               : "Today, newest first. Only you can see this list.").settingsCaption()
            }
        }
    }
}

/// The one-time sheet before "Learn from me" first turns on.
struct LearnIntroSheet: View {
    let turnOn: () -> Void
    let notNow: () -> Void
    @Environment(\.zeusPalette) private var palette

    static let records = ["Which app is in front, and when it changes", "Apps opening and quitting",
                          "Locking, sleeping and waking your Mac", "Times with no input for 5 minutes or more",
                          "How many displays are connected"]
    static let never = ["What you type, copy or paste", "Window titles, web addresses and file names",
                        "Screenshots, audio or your location"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Learn from me").settingsTitle()
            Text("Zeus records how you use this Mac so your assistant can pick better moments to help. Each morning it sends a short summary of the day before.")
                .settingsBody().fixedSize(horizontal: false, vertical: true)
            list("Zeus records", Self.records)
            list("Zeus never records", Self.never)
            Text("Apps on your private list count only as private time, with no name.").settingsCaption()
            Text(PrivacySettingsView.caveat).settingsCaption()
            HStack(spacing: ZeusTheme.Spacing.s) {
                Spacer()
                Button("Not Now", action: notNow).keyboardShortcut(.cancelAction).accessibilityLabel("Not Now")
                Button("Turn On", action: turnOn).buttonStyle(ZeusButtonStyle(.primary, size: .small)).accessibilityLabel("Turn On")
            }
        }
        .buttonStyle(ZeusButtonStyle(.secondary, size: .small))
        .padding(24)
        .frame(width: 440)
        .environment(\.zeusFontChoice, .system)
    }

    private func list(_ title: String, _ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).settingsHeading()
            ForEach(items, id: \.self) { item in
                Text("· " + item).settingsBody().fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
