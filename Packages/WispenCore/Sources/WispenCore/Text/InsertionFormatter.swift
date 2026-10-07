import Foundation

/// Makes inserted dictation fit the text around the cursor: adds a leading space when needed and
/// lowercases the first word when continuing a sentence ("I think" stays, "Tomorrow" → "tomorrow").
public enum InsertionFormatter {
    public static func prepare(_ text: String, before: String?, after: String? = nil, protectedTerms: [String] = []) -> String {
        guard var out = Optional(text), !out.isEmpty else { return text }
        let before = before ?? ""
        let lastChar = before.last
        let lastNonSpace = before.last(where: { !$0.isWhitespace })

        // Continuing a sentence → lowercase first word, unless it's "I", an acronym, or a vocabulary term.
        if let c = lastNonSpace, c.isLetter || c.isNumber || c == "," || c == ";" || c == ":" {
            let firstWord = String(out.prefix(while: { $0.isLetter || $0 == "'" }))
            let isAcronym = firstWord.count > 1 && firstWord == firstWord.uppercased()
            let protected = Set(protectedTerms)
            if !firstWord.isEmpty, firstWord != "I", !firstWord.hasPrefix("I'"), !isAcronym, !protected.contains(firstWord) {
                out = out.prefix(1).lowercased() + out.dropFirst()
            }
        }

        // Leading space after a word or punctuation (not after a space, newline, or opening bracket).
        if let c = lastChar, !c.isWhitespace, !"([{\"'“‘/@#".contains(c), let first = out.first, !",.;:!?)".contains(first) {
            out = " " + out
        }

        // Trailing space if the cursor sits right before a word.
        if let next = after?.first, next.isLetter || next.isNumber {
            out += " "
        }
        return out
    }
}

/// Detects when the microphone picked up the other side of a call from the speakers, so the same
/// words don't appear twice in a meeting transcript (once as "Others", once as "Me").
public enum TranscriptMerger {
    static func words(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// True if `candidate` is largely contained in `reference` (≥60% of its words, ignoring short texts).
    public static func isEcho(_ candidate: String, of reference: String) -> Bool {
        let c = words(candidate)
        guard c.count >= 4 else { return false }
        let r = Set(words(reference))
        let overlap = c.filter { r.contains($0) }.count
        return Double(overlap) / Double(c.count) >= 0.6
    }

    /// Whether a new mic segment duplicates any system-audio segment around the same time.
    public static func isMicEcho(_ segment: TranscriptSegment, among others: [TranscriptSegment], window: Double = 20) -> Bool {
        let nearby = others.filter { $0.end >= segment.start - window && $0.start <= segment.end + window }
        guard !nearby.isEmpty else { return false }
        return isEcho(segment.text, of: nearby.map(\.text).joined(separator: " "))
    }
}
