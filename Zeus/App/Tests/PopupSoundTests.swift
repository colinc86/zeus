import Foundation
import Testing
@testable import Zeus

/// N2: the optional pop-up sound. Nothing here plays audio: the shell gets a recording player.
@MainActor private final class RecordingSoundPlayer: PopupSoundPlaying {
    var played: [PopupSound] = []
    func play(_ sound: PopupSound) { played.append(sound) }
}

@MainActor private final class SoundFixture {
    let suite = TestDefaults.suite("zeus-popup-sound")
    let defaults: UserDefaults
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("zeus-popup-sound-\(UUID())")
    let settings: AppSettings
    let player = RecordingSoundPlayer()
    let shell: ShellController
    init() {
        defaults = UserDefaults(suiteName: suite) ?? .standard
        settings = AppSettings(defaults: defaults, userDirectory: nil)
        let cards = CardStore(fileURL: root.appendingPathComponent("cards.json"))
        shell = ShellController(defaults: defaults, cards: cards, settings: settings, popupSound: player)
        cards.onAdd = nil  // exercise the sound hook directly; never order native panels
    }
    func cleanup() { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
}

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

@Suite struct PopupSoundGateTests {
    @Test func playsOnceWhenTheBubbleAppears() {
        var gate = PopupSoundGate()
        do { let played = gate.shouldPlay(enabled: true, appeared: true, suppression: .init(), now: t0); #expect(played) }
        #expect(gate.lastPlayed == t0)
    }

    @Test func offOrAReplacedBubbleIsSilent() {
        var gate = PopupSoundGate()
        do { let played = gate.shouldPlay(enabled: false, appeared: true, suppression: .init(), now: t0); #expect(!played) }
        do { let played = gate.shouldPlay(enabled: true, appeared: false, suppression: .init(), now: t0); #expect(!played) }
        #expect(gate.lastPlayed == nil)
    }

    @Test func silentWheneverThePeekIsSuppressed() {
        let suppressed: [PeekModel.Suppression] = [
            .init(panelOpen: true),   // the conversation is open: the user may be typing, and the thread shows it
            .init(hidden: true),      // hidden, snoozed or asleep
            .init(quiet: true),       // quiet hours
        ]
        for suppression in suppressed {
            var gate = PopupSoundGate()
            do { let played = gate.shouldPlay(enabled: true, appeared: true, suppression: suppression, now: t0); #expect(!played, "\(suppression)") }
        }
        var gate = PopupSoundGate()
        let played = gate.shouldPlay(enabled: true, appeared: true, suppression: .init(), now: t0)
        #expect(played)
    }

    @Test func atMostOneSoundEveryFewSeconds() {
        var gate = PopupSoundGate()
        let gap = PopupSoundGate.minimumInterval
        #expect(gap >= 3 && gap <= 5)
        do { let played = gate.shouldPlay(enabled: true, appeared: true, suppression: .init(), now: t0); #expect(played) }
        do { let played = gate.shouldPlay(enabled: true, appeared: true, suppression: .init(), now: t0.addingTimeInterval(1)); #expect(!played) }
        do { let played = gate.shouldPlay(enabled: true, appeared: true, suppression: .init(), now: t0.addingTimeInterval(gap - 0.1)); #expect(!played) }
        do { let played = gate.shouldPlay(enabled: true, appeared: true, suppression: .init(), now: t0.addingTimeInterval(gap)); #expect(played) }
        // Silent attempts don't push the window out.
        var quiet = PopupSoundGate()
        do { let played = quiet.shouldPlay(enabled: true, appeared: true, suppression: .init(quiet: true), now: t0); #expect(!played) }
        do { let played = quiet.shouldPlay(enabled: true, appeared: true, suppression: .init(), now: t0.addingTimeInterval(1)); #expect(played) }
        // A clock that jumps backwards never locks the sound out.
        do { let played = gate.shouldPlay(enabled: true, appeared: true, suppression: .init(), now: t0.addingTimeInterval(-60)); #expect(played) }
    }
}

@MainActor @Suite struct PopupSoundShellTests {
    @Test func shellPlaysTheChosenSoundOncePerBurst() {
        let f = SoundFixture(); defer { f.cleanup() }
        f.shell.playPopupSound(appeared: true, suppression: .init(), now: t0)
        #expect(f.player.played.isEmpty, "Off by default")
        f.settings.popupSoundEnabled = true
        f.settings.popupSound = .glass
        for second in 0..<3 { f.shell.playPopupSound(appeared: true, suppression: .init(), now: t0.addingTimeInterval(Double(second))) }
        #expect(f.player.played == [.glass])
        f.shell.playPopupSound(appeared: true, suppression: .init(quiet: true), now: t0.addingTimeInterval(30))
        f.shell.playPopupSound(appeared: false, suppression: .init(), now: t0.addingTimeInterval(31))
        #expect(f.player.played == [.glass])
        f.shell.playPopupSound(appeared: true, suppression: .init(), now: t0.addingTimeInterval(32))
        #expect(f.player.played == [.glass, .glass])
    }

    @Test func settingsDefaultOffAndPersist() {
        let f = SoundFixture(); defer { f.cleanup() }
        #expect(!f.settings.popupSoundEnabled && f.settings.popupSound == .chime)
        f.settings.popupSoundEnabled = true
        f.settings.popupSound = .tink
        let reloaded = AppSettings(defaults: f.defaults, userDirectory: nil)
        #expect(reloaded.popupSoundEnabled && reloaded.popupSound == .tink)
        f.defaults.set("not-a-sound", forKey: "general.popupSoundName")
        #expect(AppSettings(defaults: f.defaults, userDirectory: nil).popupSound == .chime)
    }

    @Test func settingsCopyPromisesOnlyWhatTheGateDoes() {
        let caption = GeneralSettingsView.soundCaption
        #expect(caption.contains("alert volume") && caption.contains("quiet hours") && caption.contains("hidden"))
        #expect(!caption.contains("Focus"), "Focus is only honored when macOS shares it, so the caption doesn't promise it")
    }
}

@Suite struct ZeusChimeTests {
    @Test func everySystemSoundExists() {
        for sound in PopupSound.allCases {
            guard let name = sound.systemSoundName else { continue }
            #expect(FileManager.default.fileExists(atPath: "/System/Library/Sounds/\(name).aiff"), "\(name)")
        }
        #expect(PopupSound.chime.systemSoundName == nil)
    }

    @Test func chimeIsAShortQuietValidWAV() {
        let samples = ZeusChime.samples()
        let wav = ZeusChime.wav()
        #expect(wav.prefix(4) == Data("RIFF".utf8) && wav.subdata(in: 8..<16) == Data("WAVEfmt ".utf8))
        #expect(wav.count == 44 + samples.count * 2)
        let seconds = Double(samples.count) / Double(ZeusChime.sampleRate)
        #expect(seconds > 0.15 && seconds < 0.4, "short: \(seconds) s")
        let peak = samples.map { abs(Int($0)) }.max() ?? 0
        #expect(peak > 0 && Double(peak) <= ZeusChime.amplitude * Double(Int16.max) + 1, "subtle: peak \(peak)")
        // Starts and ends at silence, so it never clicks.
        #expect(abs(Int(samples[0])) < 100 && abs(Int(samples[samples.count - 1])) < 100)
    }
}
