import Foundation

/// Plummy's optional cloud brain: Anthropic's Messages API (Claude). Used when an Anthropic key is set
/// (menu → Anthropic API Key…). Claude is much better at multi-step tool use and, unlike the local
/// models, can SEE the screenshots look_at_screen returns. Screen text and screenshots are sent to
/// Anthropic and it bills the key, so it's strictly opt-in. Clear the key to go back to the local brain.
enum AnthropicClient {
    /// Defaults to the cheapest/fastest Claude (Haiku) — good for the speed test on a small balance.
    /// Override with `defaults write <app> anthropicModel claude-sonnet-5-5` for more capability.
    static var model: String {
        let saved = UserDefaults.standard.string(forKey: "anthropicModel")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return saved.isEmpty ? "claude-haiku-4-5-20251001" : saved
    }

    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    /// One tool the model wants to run. `id` ties the result back; `arguments` is a JSON string for runTool.
    struct ToolCall { let id: String; let name: String; let arguments: String }
    /// One assistant turn: its text, any tool calls, and whether it intends to keep going.
    struct Reply { let content: String; let toolCalls: [ToolCall] }

    enum BrainError: LocalizedError {
        case noKey, unreachable(String), badStatus(Int, String)
        var errorDescription: String? {
            switch self {
            case .noKey: return "no Anthropic key set — add one under Anthropic API Key in the menu."
            case .unreachable(let why): return "couldn't reach Anthropic (\(why))."
            case .badStatus(let code, let body): return "Anthropic said \(code): \(body.prefix(160))"
            }
        }
    }

    /// One round: send system + messages + tools, get back the assistant's text and any tool calls.
    static func chat(system: String, messages: [[String: Any]], tools: [[String: Any]]) async throws -> Reply {
        guard let key = Keychain.get(.anthropic) else { throw BrainError.noKey }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": 1024,
            "system": system,
            "messages": messages,
            "tools": tools,
        ])

        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) }
        catch { throw BrainError.unreachable(error.localizedDescription) }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw BrainError.badStatus(code, String(data: data, encoding: .utf8) ?? "") }

        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let blocks = json["content"] as? [[String: Any]] ?? []
        var text = ""
        var calls: [ToolCall] = []
        for block in blocks {
            switch block["type"] as? String {
            case "text":
                text += (block["text"] as? String ?? "")
            case "tool_use":
                let id = block["id"] as? String ?? UUID().uuidString
                let name = block["name"] as? String ?? ""
                let input = block["input"] as? [String: Any] ?? [:]
                let argsData = (try? JSONSerialization.data(withJSONObject: input)) ?? Data("{}".utf8)
                calls.append(ToolCall(id: id, name: name, arguments: String(data: argsData, encoding: .utf8) ?? "{}"))
            default:
                break
            }
        }
        return Reply(content: text.trimmingCharacters(in: .whitespacesAndNewlines), toolCalls: calls)
    }

    /// A tiny round-trip to confirm the key works and measure latency + token use (for the speed test).
    static func ping() async -> String {
        guard let key = Keychain.get(.anthropic) else { return "no Anthropic key set" }
        let start = Date()
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model, "max_tokens": 16,
            "messages": [["role": "user", "content": "Reply with exactly: ok"]],
        ])
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            if code != 200 { return "HTTP \(code): \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")" }
            let usage = json["usage"] as? [String: Any] ?? [:]
            let inTok = usage["input_tokens"] as? Int ?? 0
            let outTok = usage["output_tokens"] as? Int ?? 0
            let reply = ((json["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
            return "model=\(model) latency=\(ms)ms in=\(inTok) out=\(outTok) reply=\(reply)"
        } catch {
            return "error: \(error.localizedDescription)"
        }
    }
}
