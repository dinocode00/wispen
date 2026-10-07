import Foundation

public struct CleanupContext: Sendable {
    public var style: DictationStyle
    public var dictionary: [DictionaryEntry]
    public var snippets: [Snippet]
    public var options: CleanupOptions
    /// Name of the app the text goes into, if known (macOS).
    public var appName: String?

    public init(style: DictationStyle, dictionary: [DictionaryEntry] = [], snippets: [Snippet] = [],
                options: CleanupOptions = CleanupOptions(), appName: String? = nil) {
        self.style = style
        self.dictionary = dictionary
        self.snippets = snippets
        self.options = options
        self.appName = appName
    }
}

public struct CleanupResult: Sendable, Equatable {
    public var text: String
    public var usedAI: Bool
    /// Why AI output was rejected or skipped, for diagnostics.
    public var note: String?
}

/// Raw transcript → polished text, Wispr Flow style.
///
/// Pipeline: strip Whisper artifacts → fix vocabulary → protect snippets → on-device LLM rewrite in the
/// chosen style → validate → expand snippets → enforce vocabulary & style. Any failure falls back to the
/// deterministic `RuleBasedCleaner`, so dictation always produces something sensible.
public struct CleanupPipeline: Sendable {
    public var generator: TextGenerator?

    public init(generator: TextGenerator?) {
        self.generator = generator
    }

    public func clean(_ raw: String, context: CleanupContext) async -> CleanupResult {
        let rules = RuleBasedCleaner.clean(raw, options: context.options, style: context.style,
                                           dictionary: context.dictionary, snippets: context.snippets)
        guard !rules.isEmpty else { return CleanupResult(text: "", usedAI: false, note: "no speech") }

        guard context.options.useAI, !context.style.verbatim else {
            return CleanupResult(text: rules, usedAI: false, note: "AI off")
        }
        guard let generator, await generator.isAvailable else {
            return CleanupResult(text: rules, usedAI: false, note: "model unavailable")
        }

        var text = WhisperArtifactFilter.clean(raw)
        text = DictionaryApplier.apply(text, entries: context.dictionary)
        text = SpokenCommandProcessor.apply(text, spokenPunctuation: context.options.spokenPunctuation)
        // Very short utterances ("yes", "sounds good") gain nothing from a model round-trip.
        if text.wordCount <= 3 {
            return CleanupResult(text: rules, usedAI: false, note: "short")
        }
        let prepared = SnippetEngine.insertPlaceholders(text, snippets: context.snippets)

        let vocabulary = context.dictionary.map(\.term)
        let instructions = Prompts.cleanupInstructions(style: context.style, vocabulary: vocabulary, appName: context.appName)
        do {
            let output = try await generator.generate(
                instructions: instructions,
                prompt: Prompts.cleanupPrompt(transcript: prepared.text),
                temperature: 0.2)
            var cleaned = OutputSanitizer.clean(output)
            guard RewriteGuard.isFaithfulCleanup(input: prepared.text, output: cleaned) else {
                return CleanupResult(text: rules, usedAI: false, note: "rejected model output")
            }
            guard let expanded = SnippetEngine.expand(cleaned, placeholders: prepared.placeholders) else {
                return CleanupResult(text: rules, usedAI: false, note: "snippet lost")
            }
            cleaned = DictionaryApplier.apply(expanded, entries: context.dictionary)
            cleaned = StyleFormatter.apply(cleaned, style: context.style, protectedTerms: vocabulary)
            return CleanupResult(text: cleaned, usedAI: true, note: nil)
        } catch {
            return CleanupResult(text: rules, usedAI: false, note: error.localizedDescription)
        }
    }
}

/// Command mode: "make this more concise", "translate to Spanish", "turn this into bullet points".
public struct CommandProcessor: Sendable {
    public var generator: TextGenerator?

    public init(generator: TextGenerator?) {
        self.generator = generator
    }

    public func run(instruction rawInstruction: String, selectedText: String?, dictionary: [DictionaryEntry]) async throws -> String {
        let instruction = TextTidy.capitalizeSentences(FillerRemover.clean(WhisperArtifactFilter.clean(rawInstruction)))
        guard !instruction.isEmpty else { throw LLMError.failed("No instruction heard.") }
        guard let generator, await generator.isAvailable else {
            throw LLMError.unavailable("Command mode needs Apple Intelligence or Ollama.")
        }
        let output = try await generator.generate(
            instructions: Prompts.commandInstructions(vocabulary: dictionary.map(\.term)),
            prompt: Prompts.commandPrompt(instruction: instruction, selectedText: selectedText),
            temperature: 0.4)
        let result = DictionaryApplier.apply(OutputSanitizer.clean(output), entries: dictionary)
        guard !result.isEmpty else { throw LLMError.failed("The model returned nothing.") }
        return result
    }
}
