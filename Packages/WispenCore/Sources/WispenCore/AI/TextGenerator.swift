import Foundation

public enum LLMError: Error, Equatable, LocalizedError {
    case unavailable(String)
    case contextOverflow
    case refused
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let why): return "Language model unavailable: \(why)"
        case .contextOverflow: return "The text was too long for the on-device model."
        case .refused: return "The model declined to process this text."
        case .failed(let why): return why
        }
    }
}

/// Anything that turns instructions + prompt into text: Apple Intelligence, Ollama, a test fake.
public protocol TextGenerator: Sendable {
    /// Whether the model can be used right now.
    var isAvailable: Bool { get async }
    /// Total context window (instructions + prompt + response), in tokens.
    var contextTokens: Int { get }
    func generate(instructions: String, prompt: String, temperature: Double?) async throws -> String
}

/// Rough token estimate, deliberately conservative so chunks never overflow a small context.
public enum TokenEstimator {
    public static func estimate(_ text: String) -> Int {
        Int((Double(text.utf8.count) / 3.3).rounded(.up)) + 1
    }
}

/// Removes the chatter small models like to wrap around their answer.
public enum OutputSanitizer {
    public static func clean(_ output: String) -> String {
        var t = output.trimmed
        t = t.replacingRegex("^```[a-zA-Z]*\\n?", with: "").replacingRegex("\\n?```$", with: "")
        t = t.replacingRegex("</?(?:transcript|text|output|result|edited|answer)>", with: "")
        let preambles = [
            "^(?:sure|certainly|of course|okay|ok)[!,.]?\\s+(?:here(?:'s| is)[^:\\n]*:)?\\s*",
            "^here(?:'s| is) (?:the |your )?(?:cleaned|edited|polished|corrected|rewritten|revised|updated|final)[^:\\n]*:\\s*",
            "^(?:cleaned|edited|polished|corrected|rewritten|revised) (?:text|version|transcript)\\s*:\\s*",
            "^output\\s*:\\s*",
        ]
        for p in preambles { t = t.replacingRegex(p, with: "") }
        t = t.trimmed
        // Strip wrapping quotes the model added (but not quotes that are part of the text).
        if t.count > 2, let f = t.first, let l = t.last, (f == "\"" && l == "\"") || (f == "“" && l == "”") {
            let inner = t.dropFirst().dropLast()
            if !inner.contains("\"") && !inner.contains("“") { t = String(inner) }
        }
        return t.trimmed
    }
}

/// Detects model responses that are not a faithful rewrite (answers, refusals, truncation).
public enum RewriteGuard {
    private static let refusalStarts = [
        "i'm sorry", "i am sorry", "i can't", "i cannot", "as an ai", "i'm unable", "i am unable",
        "i apologize", "unfortunately, i", "i'm not able",
    ]

    public static func isFaithfulCleanup(input: String, output: String) -> Bool {
        let inWords = input.wordCount
        let outWords = output.wordCount
        guard outWords > 0 else { return false }
        let lowerOut = output.lowercased()
        let lowerIn = input.lowercased()
        for r in refusalStarts where lowerOut.hasPrefix(r) && !lowerIn.hasPrefix(r) { return false }
        // Cleanup removes fillers and corrections, but should never balloon or collapse.
        if Double(outWords) > Double(inWords) * 1.5 + 8 { return false }
        if inWords >= 12 && Double(outWords) < Double(inWords) * 0.3 { return false }
        return true
    }
}
