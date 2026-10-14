import AudioToolbox
import Foundation

/// The sound Zeus can play when the peek bubble pops up (Settings › General › Sounds, CONVERSATION.md §14.10).
enum PopupSound: String, CaseIterable, Identifiable, Sendable {
    case chime, glass, ping, pop, tink

    var id: String { rawValue }
    var title: String {
        switch self {
        case .chime: "Zeus chime"
        case .glass: "Glass"
        case .ping: "Ping"
        case .pop: "Pop"
        case .tink: "Tink"
        }
    }
    /// The macOS sound in /System/Library/Sounds, or nil for Zeus's own chime.
    var systemSoundName: String? { self == .chime ? nil : title }
}

/// Decides whether a pop-up makes a sound. Pure, so tests never play audio.
struct PopupSoundGate {
    /// At most one sound this often, however many pop-ups arrive.
    static let minimumInterval: TimeInterval = 4
    private(set) var lastPlayed: Date?

    /// - Parameters:
    ///   - appeared: the bubble just went from hidden to shown. A card that replaces the text of a bubble that is
    ///     already showing isn't a new pop-up.
    ///   - suppression: the peek's own rules. Zeus is silent when the conversation panel is open (the user may be
    ///     typing there and the message just appears in the thread), when hidden or snoozed, during quiet hours,
    ///     and during a macOS Focus when that's visible to Zeus.
    mutating func shouldPlay(enabled: Bool, appeared: Bool, suppression: PeekModel.Suppression, now: Date) -> Bool {
        guard enabled, appeared, suppression.allowsPeek else { return false }
        if let lastPlayed, now >= lastPlayed, now.timeIntervalSince(lastPlayed) < Self.minimumInterval { return false }
        lastPlayed = now
        return true
    }
}

/// Plays a pop-up sound. The app uses `SystemPopupSoundPlayer`; tests use a recorder.
@MainActor protocol PopupSoundPlaying: AnyObject {
    func play(_ sound: PopupSound)
}

/// Plays through System Sound Services, so the sound follows the Mac's alert volume and output device
/// (System Settings › Sound › Alert volume) like any other alert.
@MainActor final class SystemPopupSoundPlayer: PopupSoundPlaying {
    static let shared = SystemPopupSoundPlayer()
    private var soundIDs: [PopupSound: SystemSoundID] = [:]

    func play(_ sound: PopupSound) {
        guard let id = soundID(for: sound) else { return }
        AudioServicesPlaySystemSound(id)
    }

    private func soundID(for sound: PopupSound) -> SystemSoundID? {
        if let id = soundIDs[sound] { return id }
        guard let url = fileURL(for: sound) else { return nil }
        var id: SystemSoundID = 0
        guard AudioServicesCreateSystemSoundID(url as CFURL, &id) == noErr else { return nil }
        soundIDs[sound] = id
        return id
    }

    private func fileURL(for sound: PopupSound) -> URL? {
        if let name = sound.systemSoundName {
            let url = URL(fileURLWithPath: "/System/Library/Sounds/\(name).aiff")
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        // System Sound Services plays files, so the generated chime is written once per launch.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ZeusChime-\(ZeusChime.version).wav")
        do { try ZeusChime.wav().write(to: url, options: .atomic) } catch { return nil }
        return url
    }
}

/// Zeus's own pop-up chime: three quick rising square-wave notes, made here in code (no bundled or third-party audio).
enum ZeusChime {
    /// Bump when the sound changes so a stale temporary file is never played.
    static let version = 1
    static let sampleRate = 44_100
    /// B5 → E6 → B6: a small "ta-da" that ends on the octave.
    static let notes: [(frequency: Double, seconds: Double)] = [(987.77, 0.045), (1318.51, 0.045), (1975.53, 0.16)]
    /// Well below full scale: the alert volume does the rest.
    static let amplitude = 0.2

    static var duration: TimeInterval { notes.map(\.seconds).reduce(0, +) }

    /// 16-bit mono samples.
    static func samples() -> [Int16] {
        var out: [Int16] = []
        for (index, note) in notes.enumerated() {
            let count = Int(Double(sampleRate) * note.seconds)
            let last = index == notes.count - 1
            let ramp = Double(sampleRate) * 0.003  // 3 ms in and out, so notes don't click
            for i in 0..<count {
                let t = Double(i) / Double(sampleRate)
                let phase = (t * note.frequency).truncatingRemainder(dividingBy: 1)
                let square = phase < 0.25 ? 1.0 : -1.0  // 25% duty: the NES-style pulse voice
                var envelope = min(1, Double(i) / ramp, Double(count - i) / ramp)
                if last { envelope *= exp(-t / 0.05) }  // the final note rings out
                out.append(Int16((square * envelope * amplitude * Double(Int16.max)).rounded()))
            }
        }
        return out
    }

    /// The chime as a PCM WAV file.
    static func wav() -> Data {
        var pcm = Data()
        for sample in samples() { withUnsafeBytes(of: sample.littleEndian) { pcm.append(contentsOf: $0) } }
        var data = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let rate = UInt32(sampleRate)
        append(UInt32(36 + pcm.count)); data.append(Data("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(rate)
        append(rate * 2); append(UInt16(2)); append(UInt16(16))
        data.append(Data("data".utf8)); append(UInt32(pcm.count)); data.append(pcm)
        return data
    }
}
