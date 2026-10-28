import Foundation

/// Emoji for the word you just typed ("cool" → 😎 🆒 🤙), shown above the keys like the iOS keyboard.
///
/// The word list (`emoji_words.txt`, made by `scripts/gen-emoji-words.py`) comes from Unicode CLDR's
/// English emoji names and keywords (the standard emoji keyword data), ranked so the
/// expected emoji comes first, with hand-picked choices for the most common words.
public struct EmojiSuggester: Sendable {
    public static let shared = EmojiSuggester()

    private let map: [String: [String]]

    init(lines: String? = nil) {
        let text = lines ?? Bundle.module.url(forResource: "emoji_words", withExtension: "txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        var map: [String: [String]] = [:]
        for line in text.split(separator: "\n") {
            guard let tab = line.firstIndex(of: "\t") else { continue }
            map[String(line[..<tab])] = line[line.index(after: tab)...].split(separator: " ").map(String.init)
        }
        self.map = map
    }

    public var count: Int { map.count }

    /// Up to `limit` emoji for a word, best first; [] when nothing fits.
    public func emoji(for word: String, limit: Int = 2) -> [String] {
        var w = word.lowercased().replacingOccurrences(of: "’", with: "'")
        if w.hasSuffix("'s") { w.removeLast(2) }
        guard w.count >= 2, w.count <= 30 else { return [] }
        if let hit = map[w] { return Array(hit.prefix(limit)) }
        // Plurals: "cats" → cat, "boxes" → box, "parties" → party.
        for (suffix, replacement) in [("ies", "y"), ("es", ""), ("s", "")] where w.hasSuffix(suffix) && w.count > suffix.count + 2 {
            if let hit = map[String(w.dropLast(suffix.count)) + replacement] { return Array(hit.prefix(limit)) }
        }
        return []
    }
}

/// Keyboard shortcuts for snippets: type "123m" and the full address is offered above the keys.
public enum TextShortcuts {
    /// The snippet whose shortcut is the text right before the cursor (back to the last space or line).
    public static func match(before: String?, in snippets: [Snippet]) -> Snippet? {
        guard let before, let last = before.last, !last.isWhitespace else { return nil }
        var token = ""
        for c in before.reversed() {
            if c.isWhitespace { break }
            token.insert(c, at: token.startIndex)
            if token.count > 40 { return nil }
        }
        return snippets.first { $0.typedShortcut?.caseInsensitiveCompare(token) == .orderedSame }
    }
}
