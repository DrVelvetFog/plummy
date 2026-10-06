import Foundation
import Speech

/// Turns recorded audio into a transcript on-device (Apple Speech — no key, nothing leaves the Mac)
/// and keeps each session's meeting notes as plain files any agent can read:
/// ~/Documents/Plummy Notes/<date> <id>/.
enum MeetingNotes {
    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Plummy Notes", isDirectory: true)
    }

    struct Segment {
        var speaker: String
        var start: Double
        var end: Double
        var text: String
    }

    // MARK: Folders

    /// The session's folder, made the first time it's needed.
    static func folder(session: String, started: Date) -> URL {
        let fm = FileManager.default
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        writeReadmeIfNeeded()
        let tag = String(session.prefix(8)).lowercased()
        if let existing = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))?
            .first(where: { $0.lastPathComponent.hasSuffix(tag) }) {
            return existing
        }
        let name = DateFormatter.folderName.string(from: started) + " " + tag
        let url = root.appendingPathComponent(name, isDirectory: true)
        try? fm.createDirectory(at: url.appendingPathComponent("audio"), withIntermediateDirectories: true)
        return url
    }

    private static func writeReadmeIfNeeded() {
        let url = root.appendingPathComponent("README.md")
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let text = """
        # Plummy Notes

        Meeting notes recorded by the Plummy app (the little plum on the iPhone). One folder per listening \
        session, named by start time.

        In each session folder:
        - `notes.md`: the full transcript with timestamps and speaker labels, plus your questions to Plummy, \
        Plummy's replies and any research reports, in time order. Start here.
        - `session.json`: the same data, structured.
        - `audio/`: the raw recording, as five-minute AAC chunks.

        Speaker letters (A, B, …) are assigned per five-minute chunk, so the same letter can mean different people \
        in different chunks. Lines marked "(live)" are a rough live transcript for audio that hasn't been fully \
        transcribed yet.
        """
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Transcription

    /// Asks for Speech Recognition access up front (called on launch) so the prompt isn't a surprise
    /// in the middle of a session.
    static func primePermission() {
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            SFSpeechRecognizer.requestAuthorization { _ in }
        }
    }

    /// Saves the chunk's audio into the session folder and transcribes it entirely on the device.
    /// Apple Speech has no speaker diarization, so each chunk becomes one line attributed to an
    /// unknown speaker ("?"); the raw audio is always kept in `audio/` either way.
    static func transcribe(audio: Data, session: String, index: Int, sessionStarted: Date) async throws -> (segments: [Segment], folder: URL) {
        let folder = folder(session: session, started: sessionStarted)
        let audioDir = folder.appendingPathComponent("audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        let file = audioDir.appendingPathComponent(String(format: "chunk-%03d.m4a", index))
        try audio.write(to: file)
        return (try await transcribeLocally(file), folder)
    }

    enum TranscribeError: LocalizedError {
        case notAuthorized, unavailable
        var errorDescription: String? {
            switch self {
            case .notAuthorized: return "Speech Recognition is off for Plummy (System Settings, Privacy & Security, Speech Recognition)."
            case .unavailable: return "the on-device speech recognizer isn't available (its language model may still be downloading)."
            }
        }
    }

    private static let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

    private static func authorized() async -> Bool {
        if SFSpeechRecognizer.authorizationStatus() == .authorized { return true }
        return await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
    }

    /// Transcribes one saved audio file on-device. Forces on-device recognition so nothing is ever
    /// sent to Apple — if the Mac can't do it locally we fail rather than silently go to the cloud.
    private static func transcribeLocally(_ file: URL) async throws -> [Segment] {
        guard await authorized() else { throw TranscribeError.notAuthorized }
        guard let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            throw TranscribeError.unavailable
        }
        let request = SFSpeechURLRecognitionRequest(url: file)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = true
        request.taskHint = .dictation

        return try await withCheckedThrowingContinuation { cont in
            var finished = false
            recognizer.recognitionTask(with: request) { result, error in
                if finished { return }
                if let error {
                    finished = true
                    cont.resume(throwing: error)
                    return
                }
                guard let result, result.isFinal else { return }
                finished = true
                let transcription = result.bestTranscription
                let text = transcription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { cont.resume(returning: []); return }
                let start = transcription.segments.first?.timestamp ?? 0
                let last = transcription.segments.last
                let end = (last?.timestamp ?? 0) + (last?.duration ?? 0)
                cont.resume(returning: [Segment(speaker: "?", start: start, end: end, text: text)])
            }
        }
    }

    // MARK: Notes files

    /// Writes session.json and notes.md from the phone's copy of the session. Returns the folder.
    @discardableResult
    static func write(session json: [String: Any]) -> URL? {
        guard let id = json["id"] as? String, let startedAt = json["started"] as? Double else { return nil }
        let started = Date(timeIntervalSince1970: startedAt)
        let folder = folder(session: id, started: started)
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: folder.appendingPathComponent("session.json"), options: .atomic)
        }
        try? markdown(json, started: started).write(to: folder.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        return folder
    }

    private static func markdown(_ json: [String: Any], started: Date) -> String {
        let ended = (json["ended"] as? Double).map { Date(timeIntervalSince1970: $0) }
        let entries = json["entries"] as? [[String: Any]] ?? []
        let pending = json["transcribing"] as? Int ?? 0
        let day = DateFormatter()
        day.dateStyle = .full
        day.timeStyle = .short
        let clock = DateFormatter()
        clock.dateFormat = "h:mm:ss a"

        var out = ["# Plummy session: \(day.string(from: started))", ""]
        if let ended {
            let minutes = Int(ended.timeIntervalSince(started) / 60)
            out.append("Ended \(clock.string(from: ended)) (\(minutes / 60)h \(minutes % 60)m).")
        } else {
            out.append("Still recording.")
        }
        if pending > 0 { out.append("\(pending) recording chunk(s) still being transcribed; this file updates when they're done.") }
        let asked = entries.filter { $0["kind"] as? String == "asked" }.count
        if asked > 0 { out.append("You asked Plummy \(asked) question(s); they're marked inline below.") }
        out += ["", "## Transcript", ""]

        for entry in entries {
            let text = (entry["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let time = (entry["time"] as? Double).map { clock.string(from: Date(timeIntervalSince1970: $0)) } ?? ""
            switch entry["kind"] as? String {
            case "transcript":
                out.append("**[\(time)] Speaker \(entry["speaker"] as? String ?? "?"):** \(text)")
            case "heard":
                out.append("[\(time)] (live) \(text)")
            case "asked":
                out.append("> **[\(time)] You asked Plummy:** \(text)")
            case "reply":
                out.append("> **Plummy:** \(text)")
            case "report":
                let quoted = text.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
                out.append("> **Research report:**\n" + quoted)
            default:
                out.append("[\(time)] \(text)")
            }
            out.append("")
        }
        return out.joined(separator: "\n")
    }
}

private extension DateFormatter {
    static let folderName: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm"
        return f
    }()
}
