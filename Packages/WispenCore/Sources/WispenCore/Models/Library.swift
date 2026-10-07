import Foundation

/// A word or name Wispen should always spell a certain way.
public struct DictionaryEntry: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    /// Canonical spelling, e.g. "Wispen", "Kubernetes", "Siobhan".
    public var term: String
    /// What the speech recognizer tends to hear instead, e.g. ["why spin", "wisp in"].
    public var soundsLike: [String]

    public init(id: String = UUID().uuidString, term: String, soundsLike: [String] = []) {
        self.id = id
        self.term = term
        self.soundsLike = soundsLike
    }
}

/// A voice shortcut: say the trigger, get the expansion.
public struct Snippet: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var trigger: String
    public var expansion: String

    public init(id: String = UUID().uuidString, trigger: String, expansion: String) {
        self.id = id
        self.trigger = trigger
        self.expansion = expansion
    }
}

public enum DictationMode: String, Codable, Sendable {
    /// Speak text, get it typed.
    case dictation
    /// Speak an instruction that edits the selected text (or composes new text).
    case command
}

/// One finished dictation, kept for the History screen.
public struct HistoryItem: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var date: Date
    public var mode: DictationMode
    public var raw: String
    public var output: String
    public var styleID: String
    public var durationSeconds: Double
    public var usedAI: Bool
    public var appName: String?

    public init(
        id: String = UUID().uuidString, date: Date = Date(), mode: DictationMode, raw: String,
        output: String, styleID: String, durationSeconds: Double, usedAI: Bool, appName: String? = nil
    ) {
        self.id = id
        self.date = date
        self.mode = mode
        self.raw = raw
        self.output = output
        self.styleID = styleID
        self.durationSeconds = durationSeconds
        self.usedAI = usedAI
        self.appName = appName
    }

    public var wordCount: Int { output.wordCount }
}

/// Everything a user curates; exported/imported as one JSON file to sync iPhone ⇄ Mac.
public struct LibraryBundle: Codable, Sendable {
    public var dictionary: [DictionaryEntry]
    public var snippets: [Snippet]
    public var customStyles: [DictationStyle]

    public init(dictionary: [DictionaryEntry] = [], snippets: [Snippet] = [], customStyles: [DictationStyle] = []) {
        self.dictionary = dictionary
        self.snippets = snippets
        self.customStyles = customStyles
    }

    /// Merge another bundle in, replacing entries with the same term / trigger / id.
    public mutating func merge(_ other: LibraryBundle) {
        for entry in other.dictionary {
            dictionary.removeAll { $0.term.caseInsensitiveCompare(entry.term) == .orderedSame }
            dictionary.append(entry)
        }
        for snippet in other.snippets {
            snippets.removeAll { $0.trigger.caseInsensitiveCompare(snippet.trigger) == .orderedSame }
            snippets.append(snippet)
        }
        for style in other.customStyles where !style.isBuiltIn {
            customStyles.removeAll { $0.id == style.id }
            customStyles.append(style)
        }
    }
}
