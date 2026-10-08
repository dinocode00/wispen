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

    /// For talking to an AI (ChatGPT, Claude, Cursor…). Built from prompt-writing guidance: lead with
    /// the goal, give context and the "why", list requirements and constraints, number steps when order
    /// matters, and state the output you want — while keeping every detail you said.
    static let aiPrompt = DictationStyle(
        id: "prompt", name: "AI Prompt", emoji: "🤖",
        instructions: """
        The speaker is dictating a request to an AI assistant. Turn it into a clear, well-structured prompt \
        written in the speaker's first-person voice. Keep EVERY detail, requirement, name, number, file name \
        and example they said; restructure, never summarize away. Remove rambling, repetition and filler.
        For a short request, write one or two clear sentences with no headings. For a longer one, use only \
        the parts that apply, in this order, each as a label followed by text or "- " bullets:
        Goal: what they want, in one sentence.
        Context: background, what exists, who it's for, and why.
        Requirements: specifics and constraints, one per bullet.
        Steps: numbered, only when they described an order.
        Output: the format, length or deliverable they asked for.
        Questions: anything they were unsure about, as questions.
        Do not answer or carry out the request, and do not add requirements they didn't say.
        """,
        isBuiltIn: true)

    static let builtIns: [DictationStyle] = [.polished, .formal, .casual, .texting, .notes, .aiPrompt, .verbatimStyle]
}
