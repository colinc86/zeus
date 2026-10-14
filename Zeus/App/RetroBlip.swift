import AppKit

/// A short, quiet square-wave cue generated locally; no bundled or third-party audio is needed.
@MainActor
final class RetroBlip {
    static let shared = RetroBlip()
    private let sound: NSSound?

    private init() {
        let rate: UInt32 = 22050
        let samples = Int(Double(rate) * 0.025)
        var pcm = Data()
        for index in 0..<samples {
            let phase = Double(index) * 1100 / Double(rate)
            let sign = phase.truncatingRemainder(dividingBy: 1) < 0.5 ? 1.0 : -1.0
            let envelope = min(1, Double(index) / 30) * (1 - Double(index) / Double(samples))
            var value = Int16(sign * envelope * 2500).littleEndian
            withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
        }
        var data = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        append(UInt32(36 + pcm.count)); data.append(Data("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(rate)
        append(rate * 2); append(UInt16(2)); append(UInt16(16))
        data.append(Data("data".utf8)); append(UInt32(pcm.count)); data.append(pcm)
        sound = NSSound(data: data)
    }
    func play() { if sound?.isPlaying == false { sound?.play() } }
}
