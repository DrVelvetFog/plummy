import Foundation
import CryptoKit

/// How Plummy knows something — the five evidence tiers from DrVelvetFog/evidence-tier.
/// `ran` she did and observed · `read` she read in an artifact · `told` a party asserted it ·
/// `recalled` from her own memory · `inferred` derived from the others.
enum JournalTier: String { case ran, read, told, recalled, inferred }

/// Phase 7 — Plummy's evidence-tiered action journal.
///
/// Every meaningful thing she does in a turn becomes a claim tagged with a tier, and the turn is
/// written as one in-toto Statement (predicateType = evidence-tier v0), so "what did Plummy do on my
/// Mac" is answerable *and* each line says HOW it's known. `ran`/`read` claims bind to the effect or
/// the content she saw by SHA-256 digest (the content itself is never kept — only its hash — so a
/// screen read leaves a checkable fingerprint, not a copy). A human-readable `.md` mirror sits beside
/// the machine `.jsonl`. Local only; nothing here leaves the Mac.
@MainActor
final class Journal {
    static let shared = Journal()

    private struct Claim {
        let id: String
        let text: String
        let tier: JournalTier
        let evidence: [[String: Any]]
        let derivedFrom: [String]?
    }

    private var active = false
    private var claims: [Claim] = []
    private var turnStart = Date()
    private var turnID = ""
    private var ranSeq = 0
    private var standaloneSeq = 0

    private let predicateType = "https://github.com/DrVelvetFog/evidence-tier/v0"
    private let io = DispatchQueue(label: "co.visionairy.plummy.journal")

    private var on: Bool { Settings.shared.journalActions }

    /// Where the day's journal lives (next to Meeting Notes, in Documents, so it's easy to open).
    static var root: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Plummy Journal", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: Turn lifecycle (brackets one question → answer)

    /// Opens a turn: logs the user's question (`told`) and, if any, that she drew on memory (`recalled`).
    func beginTurn(question: String, recalled: [String]) {
        guard on else { return }
        active = true
        claims = []
        ranSeq = 0
        turnStart = Date()
        turnID = Self.iso(turnStart)
        add(text: "User asked: \(question)", tier: .told,
            evidence: [["kind": "party", "who": "user", "at": turnID]])
        if !recalled.isEmpty {
            let n = recalled.count
            add(text: "Drew on \(n) remembered fact\(n == 1 ? "" : "s") about the user", tier: .recalled, evidence: [])
        }
    }

    /// Closes the turn: logs the reply (`inferred`, derived from everything above) and writes the Statement.
    func endTurn(reply: String) {
        guard on, active else { return }
        active = false
        let premises = claims.map(\.id)
        add(text: "Replied: \(reply)", tier: .inferred, evidence: [], derivedFrom: premises.isEmpty ? nil : premises)
        write(subjectName: "reply", subjectDigest: Self.sha256(reply), claims: claims, at: turnStart)
        claims = []
    }

    // MARK: Logging one tool

    /// Records one tool Plummy ran. `label` is the human sentence; `result` is what gets digest-bound —
    /// the effect she observed (for `ran`) or the content she read (for `read`). `screen` marks a
    /// whole-screen read. Pointing and sleeping are skipped (no lasting effect). Called from the main
    /// actor at the point the tool actually executed, so a refused or staged action is never logged.
    func note(tool: String, label: String, result: String, screen: Bool = false) {
        guard on, let tier = Self.tier(for: tool) else { return }
        let evidence: [[String: Any]]
        switch tier {
        case .ran:
            ranSeq += 1
            let ref = active ? "plummy:\(turnID)#\(ranSeq)" : "plummy:standalone#\(nextStandalone())"
            evidence = [["kind": "action", "ref": ref, "digest": ["sha256": Self.sha256(result)]]]
        case .read:
            evidence = [["kind": "artifact", "uri": screen ? "plummy:screen" : "plummy:content",
                         "digest": ["sha256": Self.sha256(result)]]]
        default:
            evidence = []
        }
        if active {
            add(text: label, tier: tier, evidence: evidence)
        } else {
            // No turn open (the realtime voice tool path): write a one-claim Statement right away.
            let claim = Claim(id: "c1", text: label, tier: tier, evidence: evidence, derivedFrom: nil)
            write(subjectName: "_", subjectDigest: String(repeating: "0", count: 64), claims: [claim], at: Date())
        }
    }

    // MARK: Building

    private func add(text: String, tier: JournalTier, evidence: [[String: Any]], derivedFrom: [String]? = nil) {
        claims.append(Claim(id: "c\(claims.count + 1)", text: text, tier: tier, evidence: evidence, derivedFrom: derivedFrom))
    }

    private func nextStandalone() -> Int { standaloneSeq += 1; return standaloneSeq }

    // MARK: Writing (the machine record + the human mirror)

    private func write(subjectName: String, subjectDigest: String, claims: [Claim], at date: Date) {
        let statement: [String: Any] = [
            "_type": "https://in-toto.io/Statement/v1",
            "subject": [["name": subjectName, "digest": ["sha256": subjectDigest]]],
            "predicateType": predicateType,
            "predicate": [
                "producer": ["kind": "agent", "tool": "plummy", "model": Self.producerModel(), "session": Self.day(date)],
                "recordedAt": Self.iso(date),
                "claims": claims.map { claim -> [String: Any] in
                    var c: [String: Any] = ["id": claim.id, "text": claim.text,
                                            "tier": claim.tier.rawValue, "evidence": claim.evidence]
                    if let derivedFrom = claim.derivedFrom { c["derived_from"] = derivedFrom }
                    return c
                },
            ],
        ]
        let jsonLine = (try? JSONSerialization.data(withJSONObject: statement, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) }.map { $0 + "\n" } ?? ""
        let mdBlock = Self.markdown(claims: claims, at: date)
        let day = Self.day(date)
        let jsonURL = Self.root.appendingPathComponent("\(day).jsonl")
        let mdURL = Self.root.appendingPathComponent("\(day).md")
        io.async {
            Self.append(jsonLine, to: jsonURL)
            Self.append(mdBlock, to: mdURL)
        }
    }

    /// Appends text to a file, creating it (the .md gets a title) if it doesn't exist yet. Off the main actor.
    private nonisolated static func append(_ text: String, to url: URL) {
        guard !text.isEmpty, let data = text.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else if url.pathExtension == "md" {
            let title = "# Plummy — what she did on \(url.deletingPathExtension().lastPathComponent)\n\n"
            try? (title + text).data(using: .utf8)?.write(to: url)
        } else {
            try? data.write(to: url)
        }
    }

    private static let marks: [JournalTier: String] = [
        .ran: "⟨ran⟩", .read: "⟨read⟩", .told: "⟨told⟩", .recalled: "⟨recalled⟩", .inferred: "⟨inferred⟩",
    ]

    private static func markdown(claims: [Claim], at date: Date) -> String {
        var lines = ["## \(clock(date))"]
        for claim in claims { lines.append("- \(marks[claim.tier] ?? "") \(claim.text)") }
        return lines.joined(separator: "\n") + "\n\n"
    }

    // MARK: Tier mapping

    /// Which tier a tool's record carries — or nil to skip it (pointing, sleeping: no lasting effect).
    static func tier(for tool: String) -> JournalTier? {
        switch tool {
        case "look_at_screen", "read_clipboard", "read_selection": return .read
        case "point_at", "point_at_spot", "stop_pointing", "go_to_sleep", "web_research": return nil
        default: return .ran
        }
    }

    // MARK: Helpers

    private static func producerModel() -> String {
        (Settings.shared.useClaudeBrain && Keychain.get(.anthropic) != nil) ? "claude" : "ollama"
    }

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    private static func day(_ date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private static func clock(_ date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }
}
