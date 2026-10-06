import AVFoundation
import Foundation
import Speech

/// Plummy's voice on the phone — fully local, no cloud, no key.
///
/// While he's awake the mic runs so meeting notes can record. When you press and hold the screen, Apple's
/// on-device speech recognizer turns what you say into text; on release, that question is sent to the Mac,
/// which does the thinking locally (Ollama) and runs the tools. He never talks out loud: his reply is a
/// speech bubble on the Mac, with a little chirp here.
final class LiveVoice: NSObject, ObservableObject {
    enum State: Equatable { case asleep, waking, listening, asking, thinking, speaking }

    @Published private(set) var state: State = .asleep

    /// Sends a question to the Mac; calls back with the reply text (nil if the Mac went away).
    var ask: ((String, @escaping (String?) -> Void) -> Void)?
    var onStateChange: ((State) -> Void)?
    var onSessionStart: (() -> Void)?
    var onSessionEnd: (() -> Void)?
    /// For the saved transcript: a question you asked (placeholder first, then the words), and his replies.
    var onUserTurn: ((_ itemID: String, _ asked: Bool) -> Void)?
    var onUserWords: ((_ itemID: String, _ text: String, _ asked: Bool) -> Void)?
    var onReply: ((String) -> Void)?

    /// Records the whole session's audio for meeting notes (transcribed later, on the Mac).
    let recorder = ChunkRecorder()

    /// On-device text-to-speech: he reads his replies aloud. Fully local.
    private let synth = AVSpeechSynthesizer()

    override init() {
        super.init()
        synth.delegate = self
        synth.usesApplicationAudioSession = true  // play through our play-and-record session, out the speaker
        applyPreferredVoice()
    }

    /// The voice to select automatically, by name. Tony's pick — the one premium voice he has installed.
    private static let preferredVoiceName = "Matilda"

    /// Select the preferred voice once, as soon as it's installed on the device. If it isn't downloaded
    /// yet this does nothing and tries again next launch, so it takes effect after a download. The Voice
    /// picker can change it afterwards. The flag is versioned so changing the preference re-applies it.
    private func applyPreferredVoice() {
        let flag = "appliedVoice_\(Self.preferredVoiceName)"
        guard UserDefaults.standard.object(forKey: flag) == nil else { return }
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let match = voices.first { $0.name.localizedCaseInsensitiveContains(Self.preferredVoiceName) && $0.quality != .default }
            ?? voices.first { $0.name.localizedCaseInsensitiveContains(Self.preferredVoiceName) }
        if let match {
            voiceID = match.identifier
            UserDefaults.standard.set(true, forKey: flag)
        }
    }

    /// Whether he speaks his replies aloud (on) or just chirps (off).
    var speakReplies: Bool {
        get { UserDefaults.standard.object(forKey: "speakReplies") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "speakReplies") }
    }

    /// The chosen voice's identifier (from the picker), or nil to use the best available.
    var voiceID: String? {
        get { UserDefaults.standard.string(forKey: "voiceID") }
        set { UserDefaults.standard.set(newValue, forKey: "voiceID") }
    }

    /// The voice he speaks with: the user's pick if it's installed, otherwise the best available.
    var voice: AVSpeechSynthesisVoice? {
        if let id = voiceID, let chosen = AVSpeechSynthesisVoice.speechVoices().first(where: { $0.identifier == id }) {
            return chosen
        }
        return Self.bestDefaultVoice()
    }

    private var wantAwake = false
    private(set) var level: Double = 0

    var volume: Double {
        get { UserDefaults.standard.object(forKey: "volume") as? Double ?? 1 }
        set {
            UserDefaults.standard.set(newValue, forKey: "volume")
            player.volume = Float(newValue)
        }
    }

    // Audio: one engine with a continuous mic tap (for the recorder), also fed into speech recognition
    // while you're holding to ask.
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let playFormat = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
    private var audioReady = false
    private var pendingBuffers = 0

    // Speech: on-device recognition, running only while you hold the screen.
    private let recognizer = SFSpeechRecognizer()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var holding = false
    private var questionItem: String?
    private var latestTranscript = ""

    private func setState(_ new: State) {
        guard new != state else { return }
        state = new
        onStateChange?(new)
    }

    // MARK: Wake and sleep

    func toggle() {
        state == .asleep ? wake() : sleep()
    }

    func wake() {
        guard state == .asleep else { return }
        wantAwake = true
        setState(.waking)
        requestPermissions { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.onReply?("I need the microphone and speech recognition — turn them on for Plummy in Settings.")
                self.wantAwake = false
                self.setState(.asleep)
                return
            }
            guard self.state == .waking else { return }
            do {
                try self.startAudio()
            } catch {
                NSLog("Plummy: couldn't start audio: \(error)")
                self.wantAwake = false
                self.setState(.asleep)
                return
            }
            self.onSessionStart?()
            self.chirp(syllables: 2)
            self.setState(.listening)
        }
    }

    func sleep() {
        let wasRunning = wantAwake
        wantAwake = false
        holding = false
        synth.stopSpeaking(at: .immediate)
        endRecognition()
        recorder.finish()
        if wasRunning { onSessionEnd?() }
        stopAudio()
        questionItem = nil
        latestTranscript = ""
        pendingBuffers = 0
        level = 0
        setState(.asleep)
    }

    /// A quick chirp (for checking the volume), waking first if needed.
    func sayHi() {
        if state == .asleep { wake() } else { chirp(syllables: 3) }
    }

    // MARK: Hold to ask

    /// You pressed and held: start transcribing what you say now as the question.
    func beginAsk() {
        if state == .asleep { wake(); return }
        guard wantAwake, !holding else { return }
        synth.stopSpeaking(at: .immediate)  // don't talk over the new question
        holding = true
        startRecognition()
        setState(.asking)
    }

    /// You let go: finish the transcription and send the question to the Mac.
    func endAsk() {
        guard holding else { return }
        holding = false
        setState(.thinking)
        request?.endAudio()
        // If the final result is slow to land, fall back to the latest partial after a moment.
        let item = questionItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, self.state == .thinking, self.questionItem == item else { return }
            self.sendQuestion(self.latestTranscript)
        }
    }

    // MARK: Speech recognition (on-device, only while holding)

    private func startRecognition() {
        endRecognition()
        latestTranscript = ""
        let item = UUID().uuidString
        questionItem = item
        onUserTurn?(item, true)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer?.supportsOnDeviceRecognition ?? false
        self.request = request

        task = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.questionItem == item else { return }
                if let result {
                    self.latestTranscript = result.bestTranscription.formattedString
                    if result.isFinal { self.sendQuestion(self.latestTranscript) }
                } else if error != nil, self.state == .thinking {
                    self.sendQuestion(self.latestTranscript)
                }
            }
        }
    }

    private func endRecognition() {
        task?.cancel()
        task = nil
        request = nil
    }

    private func sendQuestion(_ raw: String) {
        let question = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let item = questionItem
        questionItem = nil
        endRecognition()
        if let item, !question.isEmpty { onUserWords?(item, question, true) }

        guard !question.isEmpty, let ask else {
            if wantAwake { setState(.listening) }
            return
        }
        ask(question) { [weak self] answer in
            DispatchQueue.main.async {
                guard let self, self.wantAwake else { return }
                let reply = answer?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !reply.isEmpty {
                    self.onReply?(reply)
                    self.setState(.speaking)
                    if self.speakReplies {
                        self.speak(reply)  // the synth delegate returns him to listening when done
                    } else {
                        self.chirp(syllables: min(max(reply.split(separator: " ").count, 3), 5))
                    }
                } else {
                    self.setState(.listening)
                }
            }
        }
    }

    /// Back to listening once his chirp has finished playing.
    private func finishIfQuiet() {
        guard pendingBuffers == 0 else { return }
        level = 0
        if wantAwake, state == .speaking || state == .thinking { setState(.listening) }
    }

    // MARK: Speaking (on-device TTS)

    /// Reads a reply aloud. The synthesizer delegate takes him back to listening.
    private func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.97
        utterance.pitchMultiplier = 1.04  // a touch youthful
        utterance.volume = Float(volume)
        utterance.postUtteranceDelay = 0.05
        synth.speak(utterance)
    }

    /// Speaks a short sample in a given voice, so the picker can preview it.
    func previewVoice(_ voiceID: String?) {
        #if os(iOS)
        if state == .asleep {
            // No session is running while he's asleep; bring one up so the preview is audible.
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .default)
            try? session.setActive(true)
        }
        #endif
        synth.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: "Hello — I'm Plummy. Lookit.")
        utterance.voice = voiceID.flatMap { id in AVSpeechSynthesisVoice.speechVoices().first { $0.identifier == id } }
            ?? Self.bestDefaultVoice()
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.97
        utterance.pitchMultiplier = 1.04
        utterance.volume = Float(volume)
        synth.speak(utterance)
    }

    // MARK: Voice choices

    private static func qualityRank(_ voice: AVSpeechSynthesisVoice) -> Int {
        switch voice.quality {
        case .premium: return 2
        case .enhanced: return 1
        default: return 0
        }
    }

    /// Every English voice installed on the device, best quality first — for the picker.
    static func englishVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .sorted { a, b in
                if qualityRank(a) != qualityRank(b) { return qualityRank(a) > qualityRank(b) }
                if a.language != b.language { return a.language < b.language }
                return a.name < b.name
            }
    }

    /// The best default: a quality en-GB voice, else any quality English voice, else en-GB, else anything.
    static func bestDefaultVoice() -> AVSpeechSynthesisVoice? {
        let english = englishVoices()
        if let gbQuality = english.first(where: { $0.language == "en-GB" && qualityRank($0) > 0 }) { return gbQuality }
        if let anyQuality = english.first(where: { qualityRank($0) > 0 }) { return anyQuality }
        if let gb = english.first(where: { $0.language == "en-GB" }) { return gb }
        return english.first ?? AVSpeechSynthesisVoice(language: "en-GB")
    }

    // MARK: Permissions

    private func requestPermissions(_ done: @escaping (Bool) -> Void) {
        AVAudioApplication.requestRecordPermission { mic in
            guard mic else { DispatchQueue.main.async { done(false) }; return }
            SFSpeechRecognizer.requestAuthorization { status in
                DispatchQueue.main.async { done(status == .authorized) }
            }
        }
    }

    // MARK: Audio

    private func startAudio() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
        #endif

        if !audioReady {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: playFormat)
            audioReady = true
        }
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)  // echo cancellation, so he doesn't hear his own chirp
        let inputFormat = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2400, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.recorder.append(buffer)
            if self.holding { self.request?.append(buffer) }
        }
        player.volume = Float(volume)
        engine.prepare()
        try engine.start()
        player.play()
    }

    private func stopAudio() {
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    /// A tiny cartoon chirp: a few soft, round, bell-like notes from a happy pentatonic scale,
    /// each with a little upward "boop" at the start, like a small creature humming.
    private func chirp(syllables: Int) {
        guard audioReady else { return }
        let rate = playFormat.sampleRate
        // C major pentatonic, two octaves up high (C6…E7), so it always sounds sweet together.
        let scale = [1046.5, 1174.7, 1318.5, 1568.0, 1760.0, 2093.0, 2349.3, 2637.0]
        var index = Int.random(in: 1...3)
        var samples: [Float] = []
        for i in 0..<syllables {
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
                samples.append(Float(wave * envelope * 0.26))
            }
            samples += [Float](repeating: 0, count: Int(rate * 0.028))
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let out = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { out.update(from: $0.baseAddress!, count: samples.count) }
        level = min(1, Double(syllables) * 0.25 + 0.3)
        pendingBuffers += 1
        player.scheduleBuffer(buffer) { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.pendingBuffers = max(0, self.pendingBuffers - 1)
                self.finishIfQuiet()
            }
        }
    }
}

// MARK: - Text-to-speech delegate (drives the talking bounce and returns him to listening)

extension LiveVoice: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.level = 0.6 }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.level = Double.random(in: 0.4...0.85) }  // a little mouth-movement
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.level = 0
            if self.wantAwake, self.state == .speaking { self.setState(.listening) }
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.level = 0 }
    }
}
