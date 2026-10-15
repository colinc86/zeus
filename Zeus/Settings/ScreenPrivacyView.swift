import AppKit
import SwiftUI
import ZeusDesign

struct ScreenPrivacyView: View {
    @Bindable var model: ScreenPrivacyModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Screen").settingsTitle()
            Toggle("Let Zeus look at the window in front now and then", isOn: Binding(get: { model.policy.enabled }, set: model.setEnabled))
                .accessibilityLabel("Let Zeus look at the window in front now and then")
            Text("Zeus takes a picture of the window in front at sensible moments, covers private text and blurs pictures on this Mac, and keeps a one-line description of what you were doing. Never the whole screen.").settingsCaption()
            if model.policy.enabled {
                if let caption = model.statusCaption {
                    Text(caption).settingsCaption()
                    if model.permission == .reopenRequired {
                        KeyboardButton("Reopen Zeus") { model.reopen() }.accessibilityLabel("Reopen Zeus to start taking pictures")
                    } else if model.permission != .granted {
                        KeyboardButton("Open System Settings") { model.openPermissionSettings() }.accessibilityLabel("Open Screen Recording settings")
                    }
                }
                Text("macOS may show its screen-recording indicator for a moment when Zeus takes a picture, and may ask now and then whether Zeus can still see your screen.").settingsCaption()
                if !model.modelAvailable { Text("Apple Intelligence is off, so Zeus writes simpler descriptions.").settingsCaption() }

            }
            ScreenPolicyControls(model: model).disabled(!model.policy.enabled)
        }
        .sheet(isPresented: $model.showsConsent) {
            ScreenConsentSheet(enable: { model.continueConsent() }, cancel: { model.cancelConsent() })
        }
    }
}

private struct ScreenPolicyControls: View {
    @Bindable var model: ScreenPrivacyModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ObservationScopeView(settings: model.policies, privacy: model.privacy, level: 3, onChange: { model.changed() })
            SettingsSegments(label: "Up to", options: [4, 12, 30].map { ($0, "\($0) an hour") },
                selection: Binding(get: { model.policies.screenPerHour }, set: { model.policies.screenPerHour = $0; model.changed() }))
            Text("Pictures that look the same as the last one don't count.").settingsCaption()
            SettingsSegments(label: "Keep descriptions for", options: [7, 30, 90].map { ($0, "\($0) days") },
                selection: Binding(get: { model.policy.retentionDays }, set: { value in model.policies.edit(3) { $0.retentionDays = value }; model.changed() }))
            Text("Pictures are deleted after 7 days.").settingsCaption()
            RawJournalAccessView(settings: model.policies, level: .screen)
        }
    }
}

struct ScreenConsentSheet: View {
    let enable: @MainActor @Sendable () -> Void
    let cancel: @MainActor @Sendable () -> Void
    @FocusState private var cancelFocused: Bool
    static let timing = "Zeus doesn't record your screen. It takes one picture of the window in front when something has changed: after you've switched to an app or document and stayed for 10 seconds, every 5 minutes if you stay in the same place, when you come back from a break, and when you ask. It skips the picture if the window looks the same as last time. It never takes one during a video call, while your screen is mirrored for a presentation, while a password field is active, or in private windows and apps on your private list."
    /// A containing window may provide a smaller available height; by default use the display's usable height.
    var heightLimit: CGFloat? = nil
    private var maximumHeight: CGFloat { max(420, heightLimit ?? ((NSScreen.main?.visibleFrame.height ?? 1080) - 48)) }
    var body: some View {
        ViewThatFits(in: .vertical) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Screen").settingsTitle()
                content
                footer
            }.padding(24).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 16) {
                Text("Screen").settingsTitle()
                ScrollView { content }.scrollBounceBehavior(.basedOnSize)
                footer
            }.padding(24)
        }.frame(width: 540).frame(maxHeight: maximumHeight).fixedSize(horizontal: false, vertical: true)
            .environment(\.zeusFontChoice, .system)
            .onAppear { cancelFocused = true }
    }
    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Zeus takes a picture of the window in front at sensible moments, so your assistant knows what you were looking at. Before anything is kept, Zeus covers private text and blurs pictures and faces, here on this Mac.").settingsBody()
            list("Zeus keeps", ["A picture of the window in front, with private text covered and pictures blurred, for 7 days", "A one-line description of what you were doing, for 90 days"])
            list("Zeus never keeps", ["The rest of your screen or other windows", "Anything during a video call or while presenting", "Anything while a password field is active", "Private windows and apps on your private list", "Sound"])
            Text("When Zeus looks").settingsHeading()
            Text(Self.timing).settingsCaption()
            Text("An example of what's kept").settingsHeading()
            ZeusFieldChrome {
                VStack(alignment: .leading, spacing: 8) {
                    ScreenConsentExample().frame(width: 360, height: 225)
                    Text("10:12  Safari  Reviewing account information.").font(.system(size: 11, design: .monospaced))
                }
            }.frame(width: 384)
            Text("Grey boxes are text Zeus covered. Pictures and faces are blurred. The picture is kept for 7 days, the description for 90.").settingsCaption()
            Text("Safari: Zeus takes no pictures of Safari unless you add it under Only in apps I choose. Zeus can't tell Safari's private windows apart, so those would be pictured too.").settingsCaption()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    /// The disclosure and permission caption remain visible even on a short display.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Descriptions go to your assistant in summaries, like any message. Pictures never leave this Mac unless you attach one yourself or let your assistant see them when it asks (off until you turn it on).").settingsCaption()
            Text("Next, macOS asks you to allow Zeus under Screen Recording. Zeus uses it only for these pictures.").settingsCaption()
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

/// Synthetic covered page, drawn locally; no browser, capture permission or personal picture is used.
struct ScreenConsentExample: View {
    @Environment(\.zeusPalette) private var palette
    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(palette.panel)
            Rectangle().fill(palette.frame).frame(height: 20)
            Text("Account details").settingsBody().offset(x: 14, y: 30)
            ForEach(0..<2) { row in
                Rectangle().fill(palette.fieldBorder).frame(width: row == 0 ? 190 : 150, height: 12)
                    .overlay(Rectangle().strokeBorder(palette.outline, lineWidth: 1)).offset(x: 14, y: CGFloat(58 + row * 20))
            }
            ForEach(0..<4) { row in
                Rectangle().fill(palette.secondaryText.opacity(0.5)).frame(width: CGFloat(150 - row * 10), height: 4).offset(x: 14, y: CGFloat(122 + row * 16))
            }
            Canvas { context, _ in
                let tones = [palette.fieldBorder, palette.frame, palette.secondaryText, palette.outline]
                for y in 0..<8 { for x in 0..<6 {
                    context.fill(Path(CGRect(x: CGFloat(x * 9), y: CGFloat(y * 9), width: 9, height: 9)), with: .color(tones[(x * 3 + y * 2 + x * y) % tones.count]))
                } }
            }.frame(width: 54, height: 72).offset(x: 280, y: 48)
        }.clipped().overlay(Rectangle().strokeBorder(palette.outline, lineWidth: 1))
            .accessibilityElement(children: .ignore).accessibilityLabel("Example covered Safari window, two private text areas covered and a picture blurred")
    }
}
