import Foundation
import SwiftUI
import WispenCore

/// App-wide state: the user's library and settings (persisted to JSON), plus the speech model.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    enum SpeechModelState: Equatable {
        case notLoaded
        case downloading(Double)
        case loading
        case ready
        case failed(String)

        var isReady: Bool { self == .ready }

        var label: String {
            switch self {
            case .notLoaded: return "Not downloaded"
            case .downloading(let p): return "Downloading… \(Int(p * 100))%"
            case .loading: return "Loading speech model…"
            case .ready: return "Ready"
            case .failed(let why): return "Failed: \(why)"
            }
        }
    }

    let store = WispenStore()
    let transcriber = WhisperTranscriber()
    let diarizer = SpeakerDiarizer()

    @Published var settings: WispenSettings { didSet { if settings != oldValue { persist { try store.settingsFile.save(settings) } } } }
    @Published var dictionary: [DictionaryEntry] { didSet { persist { try store.dictionaryFile.save(dictionary) } } }
    @Published var snippets: [Snippet] { didSet { persist { try store.snippetsFile.save(snippets) } } }
    @Published var customStyles: [DictationStyle] { didSet { persist { try store.stylesFile.save(customStyles) } } }
    @Published var history: [HistoryItem]
    @Published var meetings: [Meeting]
    @Published private(set) var speechModel: SpeechModelState = .notLoaded
    @Published var lastError: String?

    private init() {
        settings = store.loadSettings()
        dictionary = store.loadDictionary()
        snippets = store.loadSnippets()
        customStyles = store.loadCustomStyles()
        history = store.loadHistory()
        meetings = store.loadMeetings()
        #if os(iOS)
        // One-time move to the compact model: the big one is too heavy for background dictation.
        if !UserDefaults.standard.bool(forKey: "migratedToCompactModel") {
            UserDefaults.standard.set(true, forKey: "migratedToCompactModel")
            if settings.whisperModelID == WhisperModelOption.best {
                settings.whisperModelID = WhisperModelOption.compact
                try? store.settingsFile.save(settings)
            }
        }
        #endif
    }

    private func persist(_ work: () throws -> Void) {
        do { try work() } catch { lastError = "Couldn't save: \(error.localizedDescription)" }
    }

    /// Re-read files that another process (the keyboard) may have changed.
    func reload() {
        let s = store.loadSettings()
        if s != settings { settings = s }
        history = store.loadHistory()
    }

    // MARK: Styles

    var allStyles: [DictationStyle] { DictationStyle.builtIns + customStyles }

    func style(id: String) -> DictationStyle {
        allStyles.first { $0.id == id } ?? .polished
    }

    // MARK: Models

    var generator: TextGenerator? { GeneratorFactory.make(for: settings) }

    var whisperPrompt: String? { DictionaryApplier.whisperPrompt(entries: dictionary) }

    func cleanupContext(styleID: String, appName: String? = nil) -> CleanupContext {
        CleanupContext(style: style(id: styleID), dictionary: dictionary, snippets: snippets,
                       options: settings.cleanupOptions, appName: appName)
    }

    /// Loads (downloading on first use) the selected Whisper model.
    func prepareSpeechModel() async {
        let modelID = settings.whisperModelID
        let loadedID = await transcriber.loadedModelID
        if speechModel.isReady, loadedID == modelID { return }
        speechModel = WhisperTranscriber.isDownloaded(modelID) ? .loading : .downloading(0)
        do {
            try await transcriber.load(modelID: modelID) { fraction in
                Task { @MainActor in
                    let model = AppModel.shared
                    model.speechModel = fraction >= 1 ? .loading : .downloading(fraction)
                }
            }
            speechModel = .ready
        } catch {
            speechModel = .failed(error.localizedDescription)
        }
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        let loadedID = await transcriber.loadedModelID
        if !speechModel.isReady || loadedID != settings.whisperModelID {
            await prepareSpeechModel()
        }
        return try await transcriber.transcribe(samples, prompt: whisperPrompt, language: settings.language,
                                                englishOnlyModel: settings.whisperModel.englishOnly)
    }

    /// Words with timestamps (for meetings, so speakers can be matched to words).
    func transcribeWords(_ samples: [Float]) async throws -> [TimedText] {
        let loadedID = await transcriber.loadedModelID
        if !speechModel.isReady || loadedID != settings.whisperModelID {
            await prepareSpeechModel()
        }
        return try await transcriber.transcribeWords(samples, prompt: whisperPrompt, language: settings.language,
                                                     englishOnlyModel: settings.whisperModel.englishOnly)
    }

    // MARK: History

    func addHistory(_ item: HistoryItem) {
        guard settings.keepHistory else { return }
        history.insert(item, at: 0)
        if history.count > settings.historyLimit { history.removeLast(history.count - settings.historyLimit) }
        persist { try store.historyFile.save(history) }
    }

    func deleteHistory(at offsets: IndexSet) {
        history.remove(atOffsets: offsets)
        persist { try store.historyFile.save(history) }
    }

    func clearHistory() {
        history.removeAll()
        persist { try store.historyFile.save(history) }
    }

    var totalWordsDictated: Int { history.reduce(0) { $0 + $1.wordCount } }

    // MARK: Meetings

    func save(_ meeting: Meeting) {
        if let i = meetings.firstIndex(where: { $0.id == meeting.id }) {
            meetings[i] = meeting
        } else {
            meetings.insert(meeting, at: 0)
        }
        persist { try store.save(meeting) }
    }

    func deleteMeeting(_ meeting: Meeting) {
        meetings.removeAll { $0.id == meeting.id }
        store.deleteMeeting(id: meeting.id)
    }

    // MARK: Library import / export (sync iPhone ⇄ Mac via AirDrop/Files)

    func exportLibraryFile() throws -> URL {
        let bundle = LibraryBundle(dictionary: dictionary, snippets: snippets, customStyles: customStyles)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Wispen Library.json")
        try JSONFile<LibraryBundle>(url).save(bundle)
        return url
    }

    func importLibrary(from url: URL) throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let bundle = JSONFile<LibraryBundle>(url).load() else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var current = LibraryBundle(dictionary: dictionary, snippets: snippets, customStyles: customStyles)
        current.merge(bundle)
        dictionary = current.dictionary
        snippets = current.snippets
        customStyles = current.customStyles
    }
}
