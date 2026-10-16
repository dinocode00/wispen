import Foundation

/// Checks recap items against what was actually said, without a model.
///
/// Small models pad a recap with "action items" and "decisions" that were only ideas, or invent them
/// outright. Every decision / action / question / concern must come with the words it is based on;
/// an item whose quote isn't in the transcript is dropped (the same idea as Google's LangExtract,
/// which maps every extraction back to the source text).
public enum Grounding {
    static func words(_ s: String) -> [String] {
        s.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'") })
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty }
    }

    private static let stopwords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "of", "to", "in", "on", "for", "with", "at", "by", "is", "are", "was",
        "were", "be", "it", "this", "that", "we", "i", "you", "they", "he", "she", "our", "your", "their", "will",
        "would", "should", "can", "could", "do", "does", "did", "so", "as", "from", "about", "up", "out", "if",
    ]

    /// Lowercased words of the text, speaker labels ("Speaker 2:", "Sam:") removed.
    public struct Source: Sendable {
        let words: Set<String>
        let bigrams: Set<String>

        public init(_ text: String) {
            var all: [String] = []
            for line in text.components(separatedBy: .newlines) {
                var l = line
                if let colon = l.firstIndex(of: ":"), l.distance(from: l.startIndex, to: colon) <= 30 {
                    l = String(l[l.index(after: colon)...])
                }
                all += Grounding.words(l)
                all.append("\u{1}") // no bigram across lines
            }
            words = Set(all)
            bigrams = Set(zip(all, all.dropFirst()).map { "\($0) \($1)" })
        }
    }

    /// How much of the quote appears in the source, 0…1. Word pairs are compared (so the words have
    /// to be said together), with some slack for the model tidying up filler words or punctuation.
    public static func quoteMatch(_ quote: String, in source: Source) -> Double {
        let q = words(quote)
        guard !q.isEmpty else { return 0 }
        if q.count < 3 { return Double(q.filter(source.words.contains).count) / Double(q.count) }
        let pairs = zip(q, q.dropFirst()).map { "\($0) \($1)" }
        return Double(pairs.filter(source.bigrams.contains).count) / Double(pairs.count)
    }

    /// Share of the item's meaningful words that were said (used when the model gave no quote).
    public static func contentMatch(_ item: String, in source: Source) -> Double {
        let w = words(item).filter { !stopwords.contains($0) && $0.count > 2 }
        guard !w.isEmpty else { return 0 }
        return Double(w.filter(source.words.contains).count) / Double(w.count)
    }

    /// Whether an item is supported by the source: by its quote when there is one, otherwise by its wording.
    public static func isSupported(_ item: String, quote: String?, in source: Source) -> Bool {
        if let quote, !quote.trimmed.isEmpty { return quoteMatch(quote, in: source) >= 0.6 }
        return contentMatch(item, in: source) >= 0.75
    }

    /// Near-duplicate check for merging items from different subjects.
    public static func similar(_ a: String, _ b: String) -> Bool {
        let x = Set(words(a).filter { !stopwords.contains($0) }), y = Set(words(b).filter { !stopwords.contains($0) })
        guard !x.isEmpty, !y.isEmpty else { return a.caseInsensitiveCompare(b) == .orderedSame }
        return Double(x.intersection(y).count) / Double(x.union(y).count) >= 0.7
    }
}
