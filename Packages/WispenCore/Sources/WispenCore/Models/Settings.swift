import Foundation

/// A Whisper model the app can download and run on-device (via WhisperKit).
public struct WhisperModelOption: Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let detail: String
    public let englishOnly: Bool

    public static let best = "openai_whisper-large-v3-v20240930_turbo_632MB"
    public static let compact = "openai_whisper-small.en_217MB"

    public static let all: [WhisperModelOption] = [
        .init(id: best, name: "Best",
              detail: "Large v3 Turbo · 632 MB · any language", englishOnly: false),
        .init(id: compact, name: "Recommended for iPhone",
              detail: "Small · 217 MB · English · fast, light on memory", englishOnly: true),
        .init(id: "openai_whisper-small_216MB", name: "Small (multilingual)",
              detail: "Small · 216 MB · any language", englishOnly: false),
        .init(id: "openai_whisper-base.en", name: "Fastest",
              detail: "Base · 140 MB · English", englishOnly: true),
    ]

    /// iPhone: a compact model, because the keyboard flow transcribes while Wispen is in the background,
    /// where iOS closes apps that use a lot of memory. Mac: the best model.
    public static var defaultID: String {
        #if os(iOS)
        return compact
        #else
        return best
        #endif
    }
}

public enum LLMProvider: String, Codable, CaseIterable, Sendable {
    /// Apple Intelligence on-device model (iOS 26 / macOS 26). Free and private.
    case appleIntelligence
    /// A model served by Ollama (free, local), e.g. on your Mac.
    case ollama
    /// No language model: rule-based cleanup only.
    case rulesOnly

    public var displayName: String {
        switch self {
        case .appleIntelligence: return "Apple Intelligence (on-device)"
        case .ollama: return "Ollama (local server)"
        case .rulesOnly: return "Rules only (no AI)"
        }
    }
}

public struct WispenSettings: Codable, Equatable, Sendable {
    public var whisperModelID: String = WhisperModelOption.defaultID
    /// ISO language code ("en", "es", …) or nil to auto-detect.
    public var language: String? = "en"

    public var llmProvider: LLMProvider = .appleIntelligence
    public var ollamaURL: String = "http://localhost:11434"
    public var ollamaModel: String = "llama3.2"
    public var ollamaContextTokens: Int = 8192

    public var aiCleanup: Bool = true
    public var removeFillers: Bool = true
    public var resolveSelfCorrections: Bool = true
    public var autoFormatLists: Bool = true
    /// Turn "comma", "period", "question mark" into punctuation. "New line" always works.
    public var spokenPunctuation: Bool = false

    public var defaultStyleID: String = DictationStyle.polished.id
    /// macOS: bundle identifier → style id overrides (see `AppStyleRules`).
    public var appStyleOverrides: [String: String] = [:]

    /// iOS: keep the background "flow session" alive this long after the last dictation.
    public var sessionTimeoutMinutes: Int = 15
    public var keepHistory: Bool = true
    public var historyLimit: Int = 500

    /// macOS: also capture system audio (Zoom/Meet/Teams) for meetings, labelled "Others".
    public var meetingCaptureSystemAudio: Bool = true
    /// Tell speakers apart in meeting transcripts ("Speaker 1", "Speaker 2"…). The audio is kept in a
    /// temporary file until that's done, then deleted.
    public var meetingSpeakerLabels: Bool = true

    // iOS keyboard
    public var keyboardAutoCorrect: Bool = true
    public var keyboardAutoCapitalize: Bool = true
    public var keyboardDoubleSpacePeriod: Bool = true
    public var keyboardSuggestions: Bool = true
    public var keyboardHaptics: Bool = true
    public var keyboardSounds: Bool = false

    /// iOS: show the flow session and meetings in the Dynamic Island and on the Lock Screen.
    public var liveActivities: Bool = true

    public init() {}

    public var whisperModel: WhisperModelOption {
        WhisperModelOption.all.first { $0.id == whisperModelID } ?? WhisperModelOption.all[0]
    }

    public var cleanupOptions: CleanupOptions {
        CleanupOptions(
            useAI: aiCleanup && llmProvider != .rulesOnly,
            removeFillers: removeFillers,
            resolveSelfCorrections: resolveSelfCorrections,
            autoFormatLists: autoFormatLists,
            spokenPunctuation: spokenPunctuation)
    }

    // Tolerant decoding so new settings never wipe a user's saved file.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = WispenSettings.defaults
        whisperModelID = try c.decodeIfPresent(String.self, forKey: .whisperModelID) ?? d.whisperModelID
        language = try c.decodeIfPresent(String?.self, forKey: .language) ?? d.language
        llmProvider = (try? c.decodeIfPresent(LLMProvider.self, forKey: .llmProvider)) ?? d.llmProvider
        ollamaURL = try c.decodeIfPresent(String.self, forKey: .ollamaURL) ?? d.ollamaURL
        ollamaModel = try c.decodeIfPresent(String.self, forKey: .ollamaModel) ?? d.ollamaModel
        ollamaContextTokens = try c.decodeIfPresent(Int.self, forKey: .ollamaContextTokens) ?? d.ollamaContextTokens
        aiCleanup = try c.decodeIfPresent(Bool.self, forKey: .aiCleanup) ?? d.aiCleanup
        removeFillers = try c.decodeIfPresent(Bool.self, forKey: .removeFillers) ?? d.removeFillers
        resolveSelfCorrections = try c.decodeIfPresent(Bool.self, forKey: .resolveSelfCorrections) ?? d.resolveSelfCorrections
        autoFormatLists = try c.decodeIfPresent(Bool.self, forKey: .autoFormatLists) ?? d.autoFormatLists
        spokenPunctuation = try c.decodeIfPresent(Bool.self, forKey: .spokenPunctuation) ?? d.spokenPunctuation
        defaultStyleID = try c.decodeIfPresent(String.self, forKey: .defaultStyleID) ?? d.defaultStyleID
        appStyleOverrides = try c.decodeIfPresent([String: String].self, forKey: .appStyleOverrides) ?? d.appStyleOverrides
        sessionTimeoutMinutes = try c.decodeIfPresent(Int.self, forKey: .sessionTimeoutMinutes) ?? d.sessionTimeoutMinutes
        keepHistory = try c.decodeIfPresent(Bool.self, forKey: .keepHistory) ?? d.keepHistory
        historyLimit = try c.decodeIfPresent(Int.self, forKey: .historyLimit) ?? d.historyLimit
        meetingCaptureSystemAudio = try c.decodeIfPresent(Bool.self, forKey: .meetingCaptureSystemAudio) ?? d.meetingCaptureSystemAudio
        meetingSpeakerLabels = try c.decodeIfPresent(Bool.self, forKey: .meetingSpeakerLabels) ?? d.meetingSpeakerLabels
        keyboardAutoCorrect = try c.decodeIfPresent(Bool.self, forKey: .keyboardAutoCorrect) ?? d.keyboardAutoCorrect
        keyboardAutoCapitalize = try c.decodeIfPresent(Bool.self, forKey: .keyboardAutoCapitalize) ?? d.keyboardAutoCapitalize
        keyboardDoubleSpacePeriod = try c.decodeIfPresent(Bool.self, forKey: .keyboardDoubleSpacePeriod) ?? d.keyboardDoubleSpacePeriod
        keyboardSuggestions = try c.decodeIfPresent(Bool.self, forKey: .keyboardSuggestions) ?? d.keyboardSuggestions
        keyboardHaptics = try c.decodeIfPresent(Bool.self, forKey: .keyboardHaptics) ?? d.keyboardHaptics
        keyboardSounds = try c.decodeIfPresent(Bool.self, forKey: .keyboardSounds) ?? d.keyboardSounds
        liveActivities = try c.decodeIfPresent(Bool.self, forKey: .liveActivities) ?? d.liveActivities
    }

    private static let defaults = WispenSettings()
}

public struct CleanupOptions: Equatable, Sendable {
    public var useAI: Bool
    public var removeFillers: Bool
    public var resolveSelfCorrections: Bool
    public var autoFormatLists: Bool
    public var spokenPunctuation: Bool

    public init(useAI: Bool = true, removeFillers: Bool = true, resolveSelfCorrections: Bool = true,
                autoFormatLists: Bool = true, spokenPunctuation: Bool = false) {
        self.useAI = useAI
        self.removeFillers = removeFillers
        self.resolveSelfCorrections = resolveSelfCorrections
        self.autoFormatLists = autoFormatLists
        self.spokenPunctuation = spokenPunctuation
    }
}

/// macOS: pick a style from the frontmost app, like Wispr Flow's per-app styles.
public enum AppStyleRules {
    public static let defaults: [String: String] = [
        "com.apple.MobileSMS": DictationStyle.texting.id,
        "net.whatsapp.WhatsApp": DictationStyle.texting.id,
        "org.whispersystems.signal-desktop": DictationStyle.texting.id,
        "com.hnc.Discord": DictationStyle.casual.id,
        "com.tinyspeck.slackmacgap": DictationStyle.casual.id,
        "com.microsoft.teams2": DictationStyle.casual.id,
        "com.apple.mail": DictationStyle.formal.id,
        "com.microsoft.Outlook": DictationStyle.formal.id,
        "com.superhuman.electron": DictationStyle.formal.id,
        "com.apple.Notes": DictationStyle.notes.id,
        "md.obsidian": DictationStyle.notes.id,
        "notion.id": DictationStyle.notes.id,
    ]

    public static func styleID(forBundleID bundleID: String?, settings: WispenSettings) -> String {
        guard let bundleID else { return settings.defaultStyleID }
        return settings.appStyleOverrides[bundleID] ?? defaults[bundleID] ?? settings.defaultStyleID
    }
}
