import Foundation

/// Velvet's brain, running locally. Talks to Ollama's chat API (http://localhost:11434) instead of OpenAI,
/// so there's no key, no cloud, and no per-minute cost. The Mac hosts it; the phone only sends the question.
enum OllamaClient {
    /// The model that thinks and calls tools. Override with `defaults write` or the menu bar later.
    static var model: String {
        let saved = UserDefaults.standard.string(forKey: "ollamaModel")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return saved.isEmpty ? "qwen2.5:14b" : saved
    }

    /// Where Ollama is listening. Defaults to the local daemon.
    static var endpoint: URL {
        let host = UserDefaults.standard.string(forKey: "ollamaHost")?.trimmingCharacters(in: .whitespaces) ?? ""
        let base = host.isEmpty ? "http://127.0.0.1:11434" : host
        return URL(string: base + "/api/chat") ?? URL(string: "http://127.0.0.1:11434/api/chat")!
    }

    /// One tool the model wants to run. `arguments` is a JSON string, ready for RealtimeHost.runTool.
    struct ToolCall { let name: String; let arguments: String }
    /// One assistant turn: some text, and/or some tool calls.
    struct Reply { let content: String; let toolCalls: [ToolCall] }

    enum BrainError: LocalizedError {
        case unreachable(String), badStatus(Int, String)
        var errorDescription: String? {
            switch self {
            case .unreachable(let why): return "couldn't reach Ollama (\(why)). Is it running?"
            case .badStatus(let code, let body): return "Ollama said \(code): \(body.prefix(140))"
            }
        }
    }

    /// One chat round: send the conversation plus the tool list, get back the assistant's message.
    static func chat(messages: [[String: Any]], tools: [[String: Any]]) async throws -> Reply {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": messages,
            "tools": tools,
            "stream": false,
        ])

        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw BrainError.unreachable(error.localizedDescription)
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw BrainError.badStatus(code, String(data: data, encoding: .utf8) ?? "")
        }

        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let message = json?["message"] as? [String: Any] ?? [:]
        let content = (message["content"] as? String) ?? ""

        var calls: [ToolCall] = []
        if let raw = message["tool_calls"] as? [[String: Any]] {
            for item in raw {
                let function = item["function"] as? [String: Any] ?? [:]
                guard let name = function["name"] as? String else { continue }
                // Ollama returns arguments as a JSON object; runTool wants a JSON string.
                let arguments: String
                if let object = function["arguments"] as? [String: Any],
                   let encoded = try? JSONSerialization.data(withJSONObject: object),
                   let string = String(data: encoded, encoding: .utf8) {
                    arguments = string
                } else if let string = function["arguments"] as? String {
                    arguments = string
                } else {
                    arguments = "{}"
                }
                calls.append(ToolCall(name: name, arguments: arguments))
            }
        }
        return Reply(content: content, toolCalls: calls)
    }
}
