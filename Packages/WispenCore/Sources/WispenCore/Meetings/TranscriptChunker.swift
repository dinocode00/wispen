import Foundation

/// Splits long text into pieces under a token budget, breaking at line and sentence boundaries.
public enum TranscriptChunker {
    public static func chunk(_ text: String, maxTokens: Int, overlapSentences: Int = 0) -> [String] {
        let units = sentenceUnits(text)
        var chunks: [String] = []
        var current: [String] = []
        var currentTokens = 0

        func flush() {
            guard !current.isEmpty else { return }
            chunks.append(joinUnits(current))
            current = overlapSentences > 0 ? Array(current.suffix(overlapSentences)) : []
            currentTokens = current.reduce(0) { $0 + TokenEstimator.estimate($1) }
        }

        for unit in units {
            let tokens = TokenEstimator.estimate(unit)
            if tokens > maxTokens {
                flush()
                current = []
                currentTokens = 0
                chunks.append(contentsOf: splitByWords(unit, maxTokens: maxTokens))
                continue
            }
            if currentTokens + tokens > maxTokens { flush() }
            current.append(unit)
            currentTokens += tokens
        }
        if !current.isEmpty, chunks.isEmpty || current.count > overlapSentences {
            chunks.append(joinUnits(current))
        }
        return chunks.filter { !$0.isEmpty }
    }

    /// Sentences, keeping each speaker line's label with its first sentence.
    static func sentenceUnits(_ text: String) -> [String] {
        var units: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            var sentence = ""
            let chars = Array(line)
            for (i, c) in chars.enumerated() {
                sentence.append(c)
                if ".!?".contains(c), i + 1 == chars.count || chars[i + 1] == " " {
                    units.append(sentence.trimmed)
                    sentence = ""
                }
            }
            if !sentence.trimmed.isEmpty { units.append(sentence.trimmed) }
            if !units.isEmpty { units[units.count - 1] += "\n" }
        }
        return units
    }

    private static func joinUnits(_ units: [String]) -> String {
        var out = ""
        for u in units {
            if !out.isEmpty && !out.hasSuffix("\n") { out += " " }
            out += u
        }
        return out.trimmed
    }

    private static func splitByWords(_ text: String, maxTokens: Int) -> [String] {
        var out: [String] = []
        var current = ""
        for word in text.split(separator: " ") {
            let candidate = current.isEmpty ? String(word) : current + " " + word
            if TokenEstimator.estimate(candidate) > maxTokens, !current.isEmpty {
                out.append(current)
                current = String(word)
            } else {
                current = candidate
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}
