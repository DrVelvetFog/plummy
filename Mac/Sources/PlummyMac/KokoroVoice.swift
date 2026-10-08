import Foundation

/// Plummy's real voice: a local Kokoro TTS server (tools/voice-bakeoff/server.py) that the
/// app launches on demand and keeps warm. `synthesize` turns a reply into WAV bytes that the
/// phone plays; any failure returns nil and the phone falls back to its on-device voice, so
/// a missing checkout, venv or model never breaks speech.
@MainActor
final class KokoroVoice {
    static let shared = KokoroVoice()

    /// Menu toggle: "Her Real Voice". Off = the phone's on-device voice.
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "kokoroVoice") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "kokoroVoice") }
    }

    private let port = 4777
    private var process: Process?
    private var starting: Task<Bool, Never>?

    private var dir: String {
        let saved = UserDefaults.standard.string(forKey: "kokoroDir")
        return NSString(string: saved ?? "~/velvet/tools/voice-bakeoff").expandingTildeInPath
    }

    /// True when the server answers /health.
    private func healthy() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// Launches the server if needed and waits for the model to load (first launch ~10s).
    private func ensureRunning() async -> Bool {
        if await healthy() { return true }
        if let starting { return await starting.value }
        let task = Task<Bool, Never> { [self] in
            let python = dir + "/venv/bin/python"
            let script = dir + "/server.py"
            guard FileManager.default.isExecutableFile(atPath: python),
                  FileManager.default.fileExists(atPath: script) else { return false }
            if process?.isRunning != true {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: python)
                p.arguments = [script]
                p.currentDirectoryURL = URL(fileURLWithPath: dir)
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                do { try p.run() } catch { return false }
                process = p
            }
            for _ in 0..<40 {  // up to ~20s for the first model load
                try? await Task.sleep(for: .milliseconds(500))
                if await healthy() { return true }
                if process?.isRunning != true { return false }
            }
            return false
        }
        starting = task
        let ok = await task.value
        starting = nil
        return ok
    }

    /// WAV bytes for `text`, or nil when the voice is off or unavailable.
    func synthesize(_ text: String) async -> Data? {
        guard Self.enabled, !text.isEmpty else { return nil }
        guard await ensureRunning() else { return nil }
        guard let url = URL(string: "http://127.0.0.1:\(port)/say") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text])
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { return nil }
        return data
    }

    func stop() {
        process?.terminate()
        process = nil
    }
}
