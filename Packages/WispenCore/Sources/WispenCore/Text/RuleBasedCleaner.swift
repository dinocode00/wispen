import Foundation

/// Deterministic, offline cleanup. Used when no language model is available, for the Verbatim
/// style, and as the safety net whenever a model response looks wrong.
public enum RuleBasedCleaner {
    public static func clean(
        _ text: String,
        options: CleanupOptions,
        style: DictationStyle,
        dictionary: [DictionaryEntry] = [],
        snippets: [Snippet] = []
    ) -> String {
        var t = WhisperArtifactFilter.clean(text)
        guard !t.isEmpty else { return "" }
        t = DictionaryApplier.apply(t, entries: dictionary)
        t = SpokenCommandProcessor.apply(t, spokenPunctuation: options.spokenPunctuation)
        if options.resolveSelfCorrections { t = SelfCorrectionResolver.apply(t) }
        if options.removeFillers { t = FillerRemover.clean(t) }
        if options.autoFormatLists && !style.verbatim { t = ListFormatter.apply(t) }
        t = TextTidy.tidy(t)
        t = TextTidy.capitalizeSentences(t)
        t = TextTidy.ensureTerminalPunctuation(t)
        t = SnippetEngine.expandDirect(t, snippets: snippets)
        t = DictionaryApplier.apply(t, entries: dictionary)
        t = StyleFormatter.apply(t, style: style, protectedTerms: dictionary.map(\.term))
        return t
    }
}
