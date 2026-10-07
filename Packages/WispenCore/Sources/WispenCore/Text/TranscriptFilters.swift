import Foundation

/// Removes Whisper's non-speech artifacts ("[BLANK_AUDIO]", "(music)", "Thanks for watching!").
public enum WhisperArtifactFilter {
    private static let wholeOutputHallucinations: Set<String> = [
        "you", "thanks for watching", "thank you for watching", "thanks for watching!",
        "please subscribe", "subtitles by the amara.org community", ".", "..", "...", "bye",
    ]

    public static func clean(_ text: String) -> String {
        var t = text
        t = t.replacingRegex("<\\|[^|]*\\|>", with: " ")
        t = t.replacingRegex("\\[[^\\]]{0,40}\\]", with: " ")
        t = t.replacingRegex(
            "\\((?:music|applause|laughter|laughs|silence|inaudible|blank[_ ]audio|sighs?|coughs?|clears throat|background noise|no speech|speaking in foreign language)[^)]{0,20}\\)",
            with: " ")
        t = t.replacingRegex("\\*[^*]{0,30}\\*", with: " ")
        t = t.replacingRegex("♪+[^♪]*♪*", with: " ")
        t = TextTidy.tidy(t)
        let key = t.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " .!"))
        if wholeOutputHallucinations.contains(key) || wholeOutputHallucinations.contains(t.lowercased()) {
            return ""
        }
        return t
    }
}

/// Removes filler words, verbal tics and stutters.
public enum FillerRemover {
    /// Words that are almost never meaningful in dictation.
    private static let fillerPattern =
        "(?<![\\w'])(?:u+m+|u+h+m*|e+r+m+|e+h+|a+h+|h+m+|m+h*m+|mhm)(?![\\w'])[,.]?"

    /// Words that legitimately repeat ("that that", "had had"), so never de-duplicated.
    private static let legitimateRepeats: Set<String> = ["that", "had", "is", "do", "very", "really", "so", "no", "bye", "ha"]

    public static func clean(_ text: String) -> String {
        var t = text.replacingRegex(fillerPattern, with: "")
        // "you know" / "like" / "I mean" only when used parenthetically between commas or at a sentence start.
        t = t.replacingRegex(",\\s*(?:you know|i mean|like|sort of|kind of|basically)\\s*,", with: ",")
        t = t.replacingRegex("(^|[.!?]\\s+)(?:so,?\\s+)?(?:you know|basically|like|okay so|so yeah),\\s*", with: "$1",
                             options: [.caseInsensitive, .anchorsMatchLines])
        t = removeStutters(t)
        return TextTidy.tidy(t)
    }

    /// "I I think the the plan" -> "I think the plan"
    static func removeStutters(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "\\b(\\w+)(?:[\\s,]+\\1\\b)+", options: [.caseInsensitive]) else {
            return text
        }
        var result = text
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed()
        for match in matches {
            guard let whole = Range(match.range, in: result), let wordRange = Range(match.range(at: 1), in: result) else { continue }
            let word = String(result[wordRange])
            if legitimateRepeats.contains(word.lowercased()) || word.allSatisfy(\.isNumber) { continue }
            result.replaceSubrange(whole, with: word)
        }
        return result
    }
}

/// Turns spoken formatting commands into text: "new line", "new paragraph", and optionally punctuation words.
public enum SpokenCommandProcessor {
    public static func apply(_ text: String, spokenPunctuation: Bool) -> String {
        var t = text
        t = t.replacingRegex("[,.]?\\s*\\bnew paragraph\\b[,.]?\\s*", with: "\n\n")
        t = t.replacingRegex("[,.]?\\s*\\b(?:new line|newline|next line)\\b[,.]?\\s*", with: "\n")
        t = t.replacingRegex("[,.]?\\s*\\bbullet point\\b[,.:]?\\s*", with: "\n- ")
        if spokenPunctuation {
            let map: [(String, String)] = [
                ("question mark", "?"), ("exclamation (?:point|mark)", "!"), ("full stop", "."),
                ("period", "."), ("comma", ","), ("semicolon", ";"), ("colon", ":"),
                ("open paren(?:thesis)?", " ("), ("close paren(?:thesis)?", ")"),
                ("dash", " —"), ("ellipsis", "…"),
            ]
            for (spoken, mark) in map {
                t = t.replacingRegex("[,.]?\\s*\\b\(spoken)\\b[,.]?", with: mark.asRegexTemplate)
            }
        }
        // Clean up spaces around inserted line breaks without touching the breaks themselves.
        t = t.replacingRegex("[ \\t]*\\n[ \\t]*", with: "\n")
        return t
    }
}

/// Keeps only the final version when the speaker corrects themselves.
///
///     "let's meet at 5pm, no wait, 6pm"      -> "let's meet at 6pm"
///     "send it to John. Scratch that."       -> ""
///     "we need 3 copies, I mean 4 copies"    -> "we need 4 copies"
public enum SelfCorrectionResolver {
    /// Markers that cancel the whole sentence before them.
    private static let cancelPattern =
        "[,.]?\\s*\\b(?:scratch that|delete that|strike that|forget that|never mind that|ignore that)\\b[,.!]?"

    /// Markers that replace the words just before them with what follows.
    private static let replacePattern =
        "(?:[,.]?\\s*\\b(?:no,? wait|wait,? no|no,? sorry|sorry,? i mean|actually,? no|no,? actually|or rather|correction|i meant)\\b|,\\s*i mean\\b)[,.:]?\\s*"

    public static func apply(_ text: String) -> String {
        var t = text
        for _ in 0..<10 {
            let before = t
            t = applyCancel(t)
            t = applyReplace(t)
            if t == before { break }
        }
        return TextTidy.tidy(t)
    }

    private static func applyCancel(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: cancelPattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return text }
        let head = String(text[..<range.lowerBound])
        let tail = String(text[range.upperBound...])
        let kept = head.trimmed.isEmpty ? "" : String(head[..<sentenceStart(in: head)])
        return kept + (kept.isEmpty ? "" : " ") + tail.trimmed
    }

    private static func applyReplace(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: replacePattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return text }

        let head = String(text[..<range.lowerBound])
        let afterMarker = String(text[range.upperBound...])
        let sentenceBreak = sentenceStart(in: head)
        let earlier = String(head[..<sentenceBreak])
        let original = String(head[sentenceBreak...])

        // The correction runs to the end of its sentence.
        var correction = afterMarker
        var rest = ""
        if let end = afterMarker.firstIndex(where: { ".!?\n".contains($0) }) {
            correction = String(afterMarker[..<end])
            rest = String(afterMarker[end...])
        }

        let a = words(original)
        let b = words(correction)
        guard !b.isEmpty else {
            // "…, no wait." with nothing after: drop the marker only.
            return join(earlier, original.trimmed) + rest
        }
        guard !a.isEmpty else { return join(earlier, correction.trimmed) + rest }

        let merged = align(original: a, correction: b)
        return join(earlier, merged.joined(separator: " ")) + rest
    }

    private static func join(_ earlier: String, _ sentence: String) -> String {
        if earlier.trimmed.isEmpty { return sentence }
        if earlier.hasSuffix("\n") { return earlier + sentence }
        return earlier.trimmed + " " + sentence
    }

    /// Index right after the last sentence terminator in `text` (or start).
    private static func sentenceStart(in text: String) -> String.Index {
        var idx = text.endIndex
        while idx > text.startIndex {
            let prev = text.index(before: idx)
            let c = text[prev]
            if ".!?\n".contains(c) {
                // Only a real boundary if followed by whitespace (avoid "3.5").
                if idx == text.endIndex || text[idx].isWhitespace { return idx }
            }
            idx = prev
        }
        return text.startIndex
    }

    private static func words(_ s: String) -> [String] {
        s.split(whereSeparator: { $0.isWhitespace }).map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ",;:")) }
            .filter { !$0.isEmpty }
    }

    private static func norm(_ w: String) -> String {
        w.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }

    private static func isNumeric(_ w: String) -> Bool {
        let n = norm(w)
        let numberWords: Set<String> = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
                                         "eleven", "twelve", "noon", "midnight"]
        return n.first?.isNumber == true || numberWords.contains(n)
    }

    static func align(original a: [String], correction b: [String]) -> [String] {
        let window = max(0, a.count - 12)
        // 1. Correction restarts the phrase: "send it to John, no wait, send it to Mary".
        if let i = a.indices.reversed().first(where: { $0 >= window && norm(a[$0]) == norm(b[0]) }) {
            return Array(a[..<i]) + b
        }
        // 2. Correction ends on a word in the original: "3 copies, I mean 4 copies".
        if b.count > 1, let j = a.indices.reversed().first(where: { $0 >= window && norm(a[$0]) == norm(b[b.count - 1]) }) {
            let start = max(0, j - (b.count - 1))
            return Array(a[..<start]) + b + Array(a[(j + 1)...])
        }
        // 3. A single number/time replaces the last number: "at 5pm, no wait, 6".
        if b.count == 1, isNumeric(b[0]), let k = a.indices.reversed().first(where: { isNumeric(a[$0]) }) {
            var out = a
            out[k] = b[0]
            return out
        }
        // 4. Otherwise replace the same number of trailing words.
        let n = min(b.count, a.count)
        return Array(a[..<(a.count - n)]) + b
    }
}
