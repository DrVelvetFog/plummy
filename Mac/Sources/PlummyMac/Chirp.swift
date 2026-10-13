import AVFoundation

/// Her boop noise on the Mac — the same tiny cartoon chirp the phone makes, note for note.
///
/// Ported from `iOS/Sources/LiveVoice.swift`: a few soft, round, bell-like notes from a happy
/// pentatonic scale, each scooping up into pitch with a little wobble on the last one. Synthesized
/// rather than loaded, so there's no audio file to ship and both bodies sound identical.
@MainActor
final class Chirp {
    static let shared = Chirp()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var started = false

    private var format: AVAudioFormat {
        engine.mainMixerNode.outputFormat(forBus: 0)
    }

    private func startIfNeeded() {
        guard !started else { return }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: nil)
        do {
            try engine.start()
            player.play()
            started = true
        } catch {
            // No audio device, or output is busy. She just boops silently.
            started = false
        }
    }

    /// Play a chirp of `syllables` notes. Safe to call rapidly; extra chirps simply queue.
    func play(syllables: Int = 2, volume: Double = 1) {
        startIfNeeded()
        guard started else { return }
        let rate = format.sampleRate
        guard rate > 0 else { return }

        // C major pentatonic, two octaves up (C6…E7), so the notes always sound sweet together.
        let scale = [1046.5, 1174.7, 1318.5, 1568.0, 1760.0, 2093.0, 2349.3, 2637.0]
        var index = Int.random(in: 1...3)
        var samples: [Float] = []

        for i in 0..<max(1, syllables) {
            if i > 0 { index = min(max(index + [-1, 1, 1, 2].randomElement()!, 0), scale.count - 1) }
            let note = scale[index] * 0.5  // drop an octave: rounder, less piercing
            let duration = i == syllables - 1 ? 0.13 : Double.random(in: 0.07...0.09)
            let count = Int(duration * rate)
            var phase = 0.0
            for n in 0..<count {
                let time = Double(n) / rate
                let t = Double(n) / Double(count)
                // Scoops up into the note over the first 25 ms, with a gentle wobble on the last one.
                let scoop = 1 - 0.18 * exp(-time / 0.012)
                let wobble = i == syllables - 1 ? 1 + 0.012 * sin(time * 2 * .pi * 18) : 1
                phase += 2 * .pi * note * scoop * wobble / rate
                let attack = min(1, time / 0.006)
                let envelope = attack * exp(-t * 3.2) * (1 - pow(t, 6))
                let wave = sin(phase) + 0.12 * sin(2 * phase)
                samples.append(Float(wave * envelope * 0.26 * volume))
            }
            samples += [Float](repeating: 0, count: Int(rate * 0.028))
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channels = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for channel in 0..<Int(format.channelCount) {
            samples.withUnsafeBufferPointer { channels[channel].update(from: $0.baseAddress!, count: samples.count) }
        }
        player.scheduleBuffer(buffer, completionHandler: nil)
    }
}
