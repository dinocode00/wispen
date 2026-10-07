import Foundation

/// Where Wispen keeps its files. On iOS this is the App Group container shared by the app and the
/// keyboard; on macOS (or if the group isn't configured) it's Application Support.
public enum WispenPaths {
    /// Read from the `WispenAppGroup` Info.plist key (filled from the build setting `WISPEN_APP_GROUP`).
    public static var appGroupID: String? {
        guard let id = Bundle.main.object(forInfoDictionaryKey: "WispenAppGroup") as? String,
              !id.isEmpty, !id.contains("$(") else { return nil }
        return id
    }

    public static let root: URL = {
        #if canImport(Darwin)
        if let group = appGroupID,
           let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) {
            return ensure(url.appendingPathComponent("Wispen", isDirectory: true))
        }
        #endif
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return ensure(base.appendingPathComponent("Wispen", isDirectory: true))
    }()

    public static var meetings: URL { ensure(root.appendingPathComponent("Meetings", isDirectory: true)) }
    public static var ipc: URL { ensure(root.appendingPathComponent("IPC", isDirectory: true)) }

    @discardableResult
    static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Atomic JSON file persistence.
public struct JSONFile<Value: Codable>: Sendable {
    public let url: URL

    public init(_ url: URL) {
        self.url = url
    }

    public init(name: String, in directory: URL = WispenPaths.root) {
        self.url = directory.appendingPathComponent(name)
    }

    public func load() -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Value.self, from: data)
    }

    public func save(_ value: Value) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: url, options: [.atomic])
    }

    public func delete() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// The user's saved data. Value-type facade over the JSON files; UI layers wrap it in an ObservableObject.
public struct WispenStore: Sendable {
    public let settingsFile: JSONFile<WispenSettings>
    public let dictionaryFile: JSONFile<[DictionaryEntry]>
    public let snippetsFile: JSONFile<[Snippet]>
    public let stylesFile: JSONFile<[DictationStyle]>
    public let historyFile: JSONFile<[HistoryItem]>
    public let meetingsDirectory: URL

    public init(root: URL = WispenPaths.root) {
        settingsFile = JSONFile(name: "settings.json", in: root)
        dictionaryFile = JSONFile(name: "dictionary.json", in: root)
        snippetsFile = JSONFile(name: "snippets.json", in: root)
        stylesFile = JSONFile(name: "styles.json", in: root)
        historyFile = JSONFile(name: "history.json", in: root)
        meetingsDirectory = WispenPaths.ensure(root.appendingPathComponent("Meetings", isDirectory: true))
    }

    public func loadSettings() -> WispenSettings { settingsFile.load() ?? WispenSettings() }
    public func loadDictionary() -> [DictionaryEntry] { dictionaryFile.load() ?? [] }
    public func loadSnippets() -> [Snippet] { snippetsFile.load() ?? [] }
    public func loadCustomStyles() -> [DictationStyle] { stylesFile.load() ?? [] }
    public func loadHistory() -> [HistoryItem] { historyFile.load() ?? [] }

    public func allStyles() -> [DictationStyle] { DictationStyle.builtIns + loadCustomStyles() }

    public func style(id: String) -> DictationStyle {
        allStyles().first { $0.id == id } ?? .polished
    }

    // MARK: Meetings (one file per meeting, so a 60-minute transcript never rewrites the others)

    private func meetingFile(_ id: String) -> JSONFile<Meeting> {
        JSONFile(meetingsDirectory.appendingPathComponent("\(id).json"))
    }

    public func loadMeetings() -> [Meeting] {
        let files = (try? FileManager.default.contentsOfDirectory(at: meetingsDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { JSONFile<Meeting>($0).load() }
            .sorted { $0.startedAt > $1.startedAt }
    }

    public func save(_ meeting: Meeting) throws { try meetingFile(meeting.id).save(meeting) }
    public func deleteMeeting(id: String) { meetingFile(id).delete() }

    public func appendHistory(_ item: HistoryItem, limit: Int) throws {
        var items = loadHistory()
        items.insert(item, at: 0)
        if items.count > limit { items.removeLast(items.count - limit) }
        try historyFile.save(items)
    }

    public func exportLibrary() -> LibraryBundle {
        LibraryBundle(dictionary: loadDictionary(), snippets: loadSnippets(), customStyles: loadCustomStyles())
    }

    public func importLibrary(_ bundle: LibraryBundle) throws {
        var current = exportLibrary()
        current.merge(bundle)
        try dictionaryFile.save(current.dictionary)
        try snippetsFile.save(current.snippets)
        try stylesFile.save(current.customStyles)
    }
}
