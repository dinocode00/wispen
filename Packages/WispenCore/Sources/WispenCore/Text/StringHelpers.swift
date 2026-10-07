import Foundation

extension String {
    /// Number of whitespace-separated words.
    public var wordCount: Int {
        split(whereSeparator: { $0.isWhitespace }).count
    }

    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    func replacingRegex(_ pattern: String, with template: String,
                        options: NSRegularExpression.Options = [.caseInsensitive]) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return self }
        let range = NSRange(startIndex..., in: self)
        return regex.stringByReplacingMatches(in: self, options: [], range: range, withTemplate: template)
    }

    func matchesRegex(_ pattern: String, options: NSRegularExpression.Options = [.caseInsensitive]) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return false }
        return regex.firstMatch(in: self, range: NSRange(startIndex..., in: self)) != nil
    }

    /// Regex pattern matching this phrase case-insensitively, tolerating punctuation the
    /// recognizer may insert between words ("why spin" also matches "Why, spin").
    var flexiblePhrasePattern: String {
        let words = split(whereSeparator: { $0.isWhitespace || $0 == "-" }).map {
            NSRegularExpression.escapedPattern(for: String($0))
        }
        return "(?<![\\w])" + words.joined(separator: "[\\s,.\\-]+") + "(?![\\w])"
    }

    /// Escapes `$` and `\` so the string can be used literally as a regex template.
    var asRegexTemplate: String {
        NSRegularExpression.escapedTemplate(for: self)
    }
}

/// Small text utilities shared by the rule-based cleanup steps.
public enum TextTidy {
    /// Collapse runs of spaces, fix spacing around punctuation and remove orphaned commas.
    public static func tidy(_ text: String) -> String {
        var t = text
        t = t.replacingOccurrences(of: "\r\n", with: "\n")
        t = t.replacingRegex("[ \\t]+", with: " ")
        t = t.replacingRegex(" +([,.;:!?])", with: "$1")
        t = t.replacingRegex(",(\\s*,)+", with: ",")
        t = t.replacingRegex("([.!?])\\s*,", with: "$1")
        t = t.replacingRegex("^\\s*[,;]\\s*", with: "", options: [.anchorsMatchLines])
        t = t.replacingRegex(",\\s*([.!?])", with: "$1")
        t = t.replacingRegex("([,;:])(?=[A-Za-z])", with: "$1 ")
        t = t.replacingRegex(" *\\n *", with: "\n")
        t = t.replacingRegex("\\n{3,}", with: "\n\n")
        return t.trimmed
    }

    /// Capitalize the first letter of the text, of each sentence and of each line, and fix lone "i".
    public static func capitalizeSentences(_ text: String) -> String {
        var chars = Array(text)
        var capitalizeNext = true
        for i in chars.indices {
            let c = chars[i]
            if capitalizeNext, c.isLetter {
                chars[i] = Character(c.uppercased())
                capitalizeNext = false
            } else if c == "." || c == "!" || c == "?" || c == "\n" {
                // Don't treat decimals / abbreviations like "3.5" or "e.g." as sentence ends.
                let next = i + 1 < chars.count ? chars[i + 1] : " "
                if c == "\n" || next.isWhitespace { capitalizeNext = true }
            } else if c.isLetter || c.isNumber {
                capitalizeNext = false
            }
        }
        var result = String(chars)
        result = result.replacingRegex("\\bi\\b(?!\\.)", with: "I", options: [])
        result = result.replacingRegex("\\bi'(m|ve|ll|d)\\b", with: "I'$1", options: [])
        return result
    }

    /// Append a period if the text ends with a word character and no list/line structure.
    public static func ensureTerminalPunctuation(_ text: String) -> String {
        guard let last = text.last else { return text }
        if last.isLetter || last.isNumber || last == ")" || last == "\"" {
            // Don't punctuate list items or multi-line content's last bullet.
            let lastLine = text.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? text
            if lastLine.matchesRegex("^\\s*(\\d+\\.|[-•*])\\s") { return text }
            if text.wordCount < 3 && !text.contains(" ") { return text }
            return text + "."
        }
        return text
    }
}
