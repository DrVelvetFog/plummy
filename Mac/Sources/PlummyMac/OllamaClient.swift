import Foundation

/// Plummy's brain, running locally. Talks to Ollama's chat API (http://localhost:11434) instead of OpenAI,
/// so there's no key, no cloud, and no per-minute cost. The Mac hosts it; the phone only sends the question.
enum OllamaClient {
    /// The model that thinks and calls tools. Override with `defaults write` or the menu bar later.
    static var model: String {
        let saved = UserDefaults.standard.string(forKey: "ollamaModel")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return saved.isEmpty ? "qwen2.5:14b" : saved
    }

    /// A local vision model (e.g. "qwen3-vl:2b") that gives the brain EYES: it never takes tool calls
    /// (no local vision model does), it just gets one see-turn per screenshot and reports what's there
    /// and where. Empty = text-only. Set it from the menu bar ("Local Vision Model…").
    static var visionModel: String {
        UserDefaults.standard.string(forKey: "ollamaVisionModel")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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
    static func chat(messages: [[String: Any]], tools: [[String: Any]], model: String? = nil,
                     options: [String: Any]? = nil) async throws -> Reply {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        var body: [String: Any] = [
            "model": model ?? Self.model,
            "messages": messages,
            "stream": false,
        ]
        // Vision models reject a tools list outright, so only send one when there are tools to send.
        if !tools.isEmpty { body["tools"] = tools }
        if let options { body["options"] = options }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

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

    /// One SEE turn of the split brain: the vision model looks at a screenshot and reports what matters
    /// for the task, with 0-1000 grid positions the text brain can click. Alternating see (here) and act
    /// (the text brain's tools) is what lets small vision models help at all — none of them take tools.
    static func see(task: String, imageBase64: String) async throws -> String {
        let prompt = """
        You are the eyes of a Mac assistant. This is a screenshot of the user's screen. \
        The assistant's current task is: \(task)
        Describe only what matters for the task: what state the screen is in, and any control (button, \
        link, field) the assistant may need, each with its center as x,y on a 0-1000 grid \
        (x: 0 = left edge, 1000 = right edge; y: 0 = top edge, 1000 = bottom edge). Be brief. Do not act.
        """
        let reply = try await chat(
            messages: [["role": "user", "content": prompt, "images": [imageBase64]]],
            tools: [],
            model: visionModel,
            options: ["temperature": 0])
        return reply.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
