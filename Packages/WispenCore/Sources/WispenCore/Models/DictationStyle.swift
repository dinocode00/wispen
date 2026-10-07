import Foundation

/// A writing style applied when polishing a dictation ("Formal", "Texting", …).
public struct DictationStyle: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var emoji: String
    /// Extra guidance handed to the language model.
    public var instructions: String
    /// Lowercase the start of sentences (texting style). "I" and vocabulary terms are kept.
    public var lowercaseSentenceStarts: Bool
    /// Drop the final period of the message (texting style).
    public var dropTrailingPeriod: Bool
    /// Skip AI rewriting and only apply light rule-based cleanup.
    public var verbatim: Bool
    public var isBuiltIn: Bool

    public init(
        id: String = UUID().uuidString,
        name: String,
        emoji: String,
        instructions: String,
        lowercaseSentenceStarts: Bool = false,
        dropTrailingPeriod: Bool = false,
        verbatim: Bool = false,
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.instructions = instructions
        self.lowercaseSentenceStarts = lowercaseSentenceStarts
        self.dropTrailingPeriod = dropTrailingPeriod
        self.verbatim = verbatim
        self.isBuiltIn = isBuiltIn
    }
}

public extension DictationStyle {
    static let polished = DictationStyle(
        id: "polished", name: "Polished", emoji: "✨",
        instructions: "Clear, natural writing in the speaker's own voice. Light touch: fix errors, keep wording.",
        isBuiltIn: true)

    static let formal = DictationStyle(
        id: "formal", name: "Formal", emoji: "👔",
        instructions: "Professional and formal, suitable for email to a manager or client. Full sentences, no slang.",
        isBuiltIn: true)

    static let casual = DictationStyle(
        id: "casual", name: "Casual", emoji: "😊",
        instructions: "Friendly and conversational, like a message to a coworker. Contractions are fine.",
        isBuiltIn: true)

    static let texting = DictationStyle(
        id: "texting", name: "Texting", emoji: "💬",
        instructions: "Very casual text message to a friend. Short, relaxed, minimal punctuation, no trailing period.",
        lowercaseSentenceStarts: true, dropTrailingPeriod: true, isBuiltIn: true)

    static let notes = DictationStyle(
        id: "notes", name: "Notes", emoji: "📝",
        instructions: "Concise notes. Prefer short bullet points (\"- \") when the speaker lists several things.",
        isBuiltIn: true)

    static let verbatimStyle = DictationStyle(
        id: "verbatim", name: "Verbatim", emoji: "🎙️",
        instructions: "Keep exactly what was said.",
        verbatim: true, isBuiltIn: true)

    static let builtIns: [DictationStyle] = [.polished, .formal, .casual, .texting, .notes, .verbatimStyle]
}
