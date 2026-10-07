import Foundation

/// Typing rules for the Wispen QWERTY keyboard, kept free of UIKit so they're unit-testable.
public enum KeyboardTextLogic {
    public enum Capitalization: Sendable {
        case none, words, sentences, allCharacters
    }

    /// The word being typed right before the cursor ("hel" in "say hel").
    public static func currentWord(before: String?) -> String {
        guard let before else { return "" }
        var word = ""
        for c in before.reversed() {
            if c.isLetter || c.isNumber || c == "'" || c == "’" { word.insert(c, at: word.startIndex) } else { break }
        }
        while let f = word.first, f == "'" || f == "’" { word.removeFirst() }
        return word
    }

    /// Whether the next letter should be uppercase.
    public static func shouldCapitalize(before: String?, mode: Capitalization) -> Bool {
        switch mode {
        case .none: return false
        case .allCharacters: return true
        case .words:
            guard let last = before?.last else { return true }
            return last.isWhitespace
        case .sentences:
            guard let before, !before.isEmpty else { return true }
            if before.last == "\n" { return true }
            guard before.last?.isWhitespace == true else { return false }
            let trimmed = before.trimmingCharacters(in: .whitespaces)
            guard let end = trimmed.last else { return true }
            return ".!?\n".contains(end)
        }
    }

    /// Double-tapping space after a word types ". " (like the system keyboard).
    public static func shouldInsertDoubleSpacePeriod(before: String?) -> Bool {
        guard let before, before.count >= 2, before.last == " " else { return false }
        let prev = before[before.index(before.endIndex, offsetBy: -2)]
        return prev.isLetter || prev.isNumber || prev == ")" || prev == "\"" || prev == "”" || prev == "'"
    }

    /// Damerau–Levenshtein (optimal string alignment) distance.
    public static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var d = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { d[i][0] = i }
        for j in 0...b.count { d[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)
                }
            }
        }
        return d[a.count][b.count]
    }

    /// Gives `suggestion` the same casing pattern as what was typed ("Teh" → "The", "TEH" → "THE").
    public static func matchCase(_ suggestion: String, to typed: String) -> String {
        let letters = typed.filter(\.isLetter)
        if letters.count > 1, letters == letters.uppercased() { return suggestion.uppercased() }
        if let f = typed.first, f.isUppercase { return suggestion.prefix(1).uppercased() + suggestion.dropFirst() }
        return suggestion
    }

    /// Conservative autocorrect: only fixes clear typos (one edit away, two for long words), never
    /// touches acronyms, numbers, or your Wispen dictionary words.
    public static func autocorrection(for word: String, guesses: [String], protectedTerms: Set<String>) -> String? {
        guard word.count >= 3, word.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "’" }) else { return nil }
        let letters = word.filter(\.isLetter)
        if letters == letters.uppercased() { return nil }
        let lower = word.lowercased()
        if protectedTerms.contains(where: { $0.lowercased() == lower }) { return nil }
        let maxDistance = word.count >= 7 ? 2 : 1
        for guess in guesses.prefix(3) where !guess.contains(" ") && !guess.contains("-") {
            if guess.lowercased() == lower { return nil }
            if editDistance(lower, guess.lowercased()) <= maxDistance {
                return matchCase(guess, to: word)
            }
        }
        return nil
    }

    /// Up to `limit` suggestions for the word being typed: vocabulary terms first, then spelling
    /// corrections, then completions; de-duplicated and cased like the typed word.
    public static func suggestions(for word: String, vocabulary: [String], corrections: [String], completions: [String],
                                   limit: Int = 2) -> [String] {
        guard !word.isEmpty else { return [] }
        let lower = word.lowercased()
        var out: [String] = []
        var seen: Set<String> = [lower]
        let vocabMatches = vocabulary.filter { $0.lowercased().hasPrefix(lower) && $0.lowercased() != lower }
        for candidate in vocabMatches.map({ $0 }) + corrections.map({ matchCase($0, to: word) }) + completions.map({ matchCase($0, to: word) }) {
            let key = candidate.lowercased()
            guard !seen.contains(key), !candidate.isEmpty else { continue }
            seen.insert(key)
            out.append(candidate)
            if out.count == limit { break }
        }
        return out
    }
}
