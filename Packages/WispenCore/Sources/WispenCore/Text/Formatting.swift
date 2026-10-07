import Foundation

/// Turns spoken enumerations into numbered lists.
///
///     "my goals are first ship the app second write docs third rest"
///     -> "My goals are:\n1. Ship the app\n2. Write docs\n3. Rest"
public enum ListFormatter {
    private static let ordinals = ["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth"]
    private static let numberWords = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]

    public static func apply(_ text: String) -> String {
        if let r = format(text, markers: ordinals.map { "\($0)(?:ly)?" }, minimumItems: 3) { return r }
        if let r = format(text, markers: numberWords.map { "number \($0)" }, minimumItems: 2) { return r }
        return text
    }

    private static func format(_ text: String, markers: [String], minimumItems: Int) -> String? {
        var positions: [(range: Range<String.Index>, index: Int)] = []
        var searchStart = text.startIndex
        for (i, marker) in markers.enumerated() {
            // "first of all" is a discourse marker, not a list item.
            let pattern = "(?<![\\w])\(marker)(?![\\w])(?!\\s+of all)[,:]?\\s*"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
            let range = NSRange(searchStart..., in: text)
            guard let m = regex.firstMatch(in: text, range: range), let r = Range(m.range, in: text) else { break }
            positions.append((r, i))
            searchStart = r.upperBound
        }
        guard positions.count >= minimumItems else { return nil }

        var intro = String(text[..<positions[0].range.lowerBound]).trimmed
        var items: [String] = []
        for (n, pos) in positions.enumerated() {
            let end = n + 1 < positions.count ? positions[n + 1].range.lowerBound : text.endIndex
            var item = String(text[pos.range.upperBound..<end]).trimmed
            item = item.replacingRegex("(?:[,;.]\\s*)?(?:and|then|and then)?[,;.]?$", with: "").trimmed
            item = item.replacingRegex("[,;]$", with: "").trimmed
            guard !item.isEmpty else { return nil }
            items.append(item.prefix(1).uppercased() + item.dropFirst())
        }
        // Keep a final sentence after the last item if it clearly starts a new sentence.
        var outro = ""
        if let last = items.last, let dot = last.range(of: ". ") {
            items[items.count - 1] = String(last[..<dot.lowerBound])
            outro = String(last[dot.upperBound...]).trimmed
        }

        intro = intro.replacingRegex("[,;:.]?$", with: "")
        var out = ""
        if !intro.isEmpty { out = intro + ":\n" }
        out += items.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        if !outro.isEmpty { out += "\n\n" + outro }
        return out
    }
}

/// Enforces the custom vocabulary: fixes mis-hearings and canonical casing.
public enum DictionaryApplier {
    public static func apply(_ text: String, entries: [DictionaryEntry]) -> String {
        guard !entries.isEmpty else { return text }
        var t = text
        // Longest phrases first so "New York City" wins over "New York".
        let replacements: [(String, String)] = entries.flatMap { entry -> [(String, String)] in
            let term = entry.term.trimmed
            guard !term.isEmpty else { return [] }
            return ([term] + entry.soundsLike).map { ($0.trimmed, term) }.filter { !$0.0.isEmpty }
        }.sorted { $0.0.count > $1.0.count }

        for (variant, term) in replacements {
            t = t.replacingRegex(variant.flexiblePhrasePattern, with: term.asRegexTemplate)
        }
        return t
    }

    /// Prompt text that biases Whisper toward the user's vocabulary.
    public static func whisperPrompt(entries: [DictionaryEntry]) -> String? {
        let terms = entries.map(\.term).filter { !$0.isEmpty }
        guard !terms.isEmpty else { return nil }
        return "Glossary: " + terms.prefix(60).joined(separator: ", ") + "."
    }
}

/// Voice shortcuts. Before AI cleanup, triggers become `{{snippet_N}}` placeholders the model
/// is told to keep; afterwards they're expanded. This keeps long expansions (addresses, links,
/// signatures) byte-for-byte exact.
public enum SnippetEngine {
    public struct Prepared: Sendable, Equatable {
        public var text: String
        public var placeholders: [String: String]
    }

    public static func insertPlaceholders(_ text: String, snippets: [Snippet]) -> Prepared {
        var t = text
        var map: [String: String] = [:]
        var n = 0
        for snippet in snippets.sorted(by: { $0.trigger.count > $1.trigger.count }) {
            let trigger = snippet.trigger.trimmed
            guard !trigger.isEmpty,
                  let regex = try? NSRegularExpression(pattern: trigger.flexiblePhrasePattern, options: [.caseInsensitive]) else { continue }
            while let m = regex.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)), let r = Range(m.range, in: t) {
                n += 1
                let token = "{{snippet_\(n)}}"
                map[token] = snippet.expansion
                t.replaceSubrange(r, with: token)
            }
        }
        return Prepared(text: t, placeholders: map)
    }

    /// Returns nil if a placeholder went missing or was duplicated (so the caller can fall back).
    public static func expand(_ text: String, placeholders: [String: String]) -> String? {
        var t = text
        for (token, expansion) in placeholders {
            let core = token.dropFirst(2).dropLast(2) // snippet_N
            let pattern = "\\{\\{\\s*\(core)\\s*\\}\\}"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
            let count = regex.numberOfMatches(in: t, range: NSRange(t.startIndex..., in: t))
            guard count == 1 else { return nil }
            t = regex.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t),
                                               withTemplate: expansion.asRegexTemplate)
        }
        return t
    }

    /// Simple direct expansion without placeholders (used by the rule-based path).
    public static func expandDirect(_ text: String, snippets: [Snippet]) -> String {
        let prepared = insertPlaceholders(text, snippets: snippets)
        return expand(prepared.text, placeholders: prepared.placeholders) ?? text
    }
}

/// Mechanical style touches that should hold no matter what the model returns.
public enum StyleFormatter {
    public static func apply(_ text: String, style: DictationStyle, protectedTerms: [String] = []) -> String {
        var t = text
        if style.lowercaseSentenceStarts {
            t = lowercaseSentenceStarts(t, protectedTerms: Set(protectedTerms))
        }
        if style.dropTrailingPeriod, t.hasSuffix("."), !t.hasSuffix("..") {
            t.removeLast()
        }
        return t
    }

    private static func lowercaseSentenceStarts(_ text: String, protectedTerms: Set<String>) -> String {
        guard let regex = try? NSRegularExpression(pattern: "(^|[.!?]\\s+|\\n)([A-Z][\\w']*)", options: []) else { return text }
        var result = text
        let ns = text as NSString
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let word = ns.substring(with: m.range(at: 2))
            let isAcronym = word.count > 1 && word == word.uppercased()
            if word == "I" || word.hasPrefix("I'") || isAcronym || protectedTerms.contains(word) { continue }
            guard let r = Range(m.range(at: 2), in: result) else { continue }
            result.replaceSubrange(r, with: word.prefix(1).lowercased() + word.dropFirst())
        }
        return result
    }
}
