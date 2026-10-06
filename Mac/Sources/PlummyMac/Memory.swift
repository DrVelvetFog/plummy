import Foundation

/// What Plummy remembers about the user across sessions — short facts she chooses to keep. Stored
/// locally in Application Support and only ever read back into her own prompt. Deduped and capped.
enum Memory {
    private static let maxFacts = 60
    private static let maxLength = 200

    struct Item: Codable { var text: String; var savedAt: Date }

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Plummy", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("memory.json")
    }

    private static func load() -> [Item] {
        guard let data = try? Data(contentsOf: fileURL),
              let items = try? JSONDecoder().decode([Item].self, from: data) else { return [] }
        return items
    }

    private static func store(_ items: [Item]) {
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: fileURL) }
    }

    /// The remembered facts, oldest first.
    static func facts() -> [String] { load().map(\.text) }

    /// Remembers one short fact. Trims, clips to a sane length, skips a near-duplicate, caps the count.
    @discardableResult
    static func remember(_ text: String) -> Bool {
        let fact = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxLength))
        guard !fact.isEmpty else { return false }
        var items = load()
        if items.contains(where: { $0.text.compare(fact, options: .caseInsensitive) == .orderedSame }) { return false }
        items.append(Item(text: fact, savedAt: Date()))
        if items.count > maxFacts { items.removeFirst(items.count - maxFacts) }
        store(items)
        return true
    }

    /// Forgets facts matching `match` (case-insensitive substring), or all of them for "everything"/"all".
    /// Returns how many were removed.
    @discardableResult
    static func forget(_ match: String) -> Int {
        let needle = match.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return 0 }
        if needle == "everything" || needle == "all" {
            let count = load().count
            store([])
            return count
        }
        var items = load()
        let before = items.count
        items.removeAll { $0.text.lowercased().contains(needle) }
        store(items)
        return before - items.count
    }

    static func forgetAll() { store([]) }
}
