import AudioToolbox
import SwiftUI
import UIKit
import WispenCore

@MainActor
final class KeyboardModel: ObservableObject {
    enum Layer { case letters, numbers, symbols }
    enum Shift { case off, once, locked }

    // Dictation
    @Published var state: FlowSessionState = .inactive
    @Published var styleID: String
    @Published var hasSelection = false
    @Published var message: String?
    @Published var canUndo = false
    /// A finished dictation that couldn't be typed automatically; the toolbar offers an Insert button.
    @Published var pendingInsert: String?
    /// iOS can keep an old, hidden copy of the keyboard alive after you switch apps. Only the copy
    /// that's on screen may type results, or the text goes into a disconnected text field.
    private var isVisible = false
    /// Set between tapping the mic and the app confirming it's recording.
    @Published private var waitingSince: Date?

    // Typing
    @Published var layer: Layer = .letters
    @Published var shift: Shift = .once
    @Published var suggestions: [String] = []
    @Published var currentWord = ""
    @Published var showStyles = false
    @Published private(set) var returnKeyLabel: String?

    let styles: [DictationStyle]
    let settings: WispenSettings
    /// Look and touch effects; changes in the Wispen app apply right away.
    @Published private(set) var theme: KeyboardTheme
    let effects = KeyEffectsEngine()
    private let store = WispenStore()
    private weak var controller: KeyboardViewController?
    private var poll: Timer?
    private var messageTimer: Timer?
    private var lastInsertion: (text: String, replaced: String?)?
    private var lastAutocorrect: (original: String, corrected: String)?
    private var lastShiftTap = Date.distantPast
    private let defaults = UserDefaults.standard
    private let protectedTerms: [String]
    private let checker = UITextChecker()
    private lazy var checkerLanguage: String = {
        let available = UITextChecker.availableLanguages
        let preferred = Locale.preferredLanguages.first?.replacingOccurrences(of: "-", with: "_") ?? "en_US"
        if available.contains(preferred) { return preferred }
        let code = String(preferred.prefix(2))
        return available.first { $0.hasPrefix(code) } ?? "en_US"
    }()

    init(controller: KeyboardViewController) {
        self.controller = controller
        styles = store.allStyles()
        protectedTerms = store.loadDictionary().map(\.term)
        settings = store.loadSettings()
        theme = settings.keyboardTheme
        styleID = UserDefaults.standard.string(forKey: "keyboardStyleID") ?? settings.defaultStyleID
        // Your dictionary words are never "misspelled".
        for term in protectedTerms where !UITextChecker.hasLearnedWord(term) { UITextChecker.learnWord(term) }

        DarwinNotifier.shared.observe(.state) { [weak self] in Task { @MainActor in self?.refreshState() } }
        DarwinNotifier.shared.observe(.result) { [weak self] in Task { @MainActor in self?.consumeResult() } }
        DarwinNotifier.shared.observe(.theme) { [weak self] in Task { @MainActor in self?.reloadTheme() } }
        effects.apply(theme)
    }

    var waitingForApp: Bool {
        guard let since = waitingSince else { return false }
        return Date().timeIntervalSince(since) < 10
    }

    var proxy: UITextDocumentProxy? { controller?.textDocumentProxy }
    var hasFullAccess: Bool { controller?.hasFullAccess ?? false }
    var needsGlobeKey: Bool { controller?.needsInputModeSwitchKey ?? true }
    var style: DictationStyle { styles.first { $0.id == styleID } ?? .polished }

    /// The voice panel replaces the keys while Wispen is listening or writing.
    var showsVoicePanel: Bool { isRecording || isWorking || waitingForApp }

    func selectStyle(_ id: String) {
        styleID = id
        defaults.set(id, forKey: "keyboardStyleID")
        showStyles = false
    }

    // MARK: Lifecycle

    func appeared() {
        isVisible = true
        reloadTheme()
        // Lets the Wispen app show "keyboard set up ✓" (this write only works with Full Access).
        try? FlowIPC.keyboardStatusFile.save(KeyboardStatus(hasFullAccess: hasFullAccess))
        if !hasFullAccess {
            show("Turn on Allow Full Access so Wispen can dictate: Settings › General › Keyboard › Keyboards › Wispen.", sticky: true)
        }
        refreshState()
        refreshContext()
        consumeResult()
        // Darwin notifications can be missed while the keyboard is being set up, so also poll lightly.
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refreshState()
                if self.state.phase != .recording { self.consumeResult() }
            }
        }
    }

    func reloadTheme() {
        let t = store.loadSettings().keyboardTheme
        if t != theme { theme = t }
        effects.apply(t)
    }

    func disappeared() {
        isVisible = false
        poll?.invalidate()
        poll = nil
    }

    /// The host app changed the text or selection.
    func refreshContext() {
        hasSelection = !(proxy?.selectedText ?? "").isEmpty
        returnKeyLabel = Self.label(for: proxy?.returnKeyType)
        updateShift()
        updateSuggestions()
    }

    func refreshState() {
        guard let s = FlowIPC.stateFile.load() else {
            state = .inactive
            return
        }
        let previous = state.phase
        state = s.isAlive() ? s : .inactive
        if state.phase == .recording || state.phase == .error { waitingSince = nil }
        if state.phase == .error, let m = state.message { show(m, sticky: true) }
        // The app vanished mid-dictation (iOS closed it, or it crashed): say so instead of going quiet.
        if state.phase == .inactive, [.recording, .transcribing, .polishing].contains(previous) {
            show("Wispen was closed before it finished. Tap 🎤 to start again.", sticky: true)
        }
    }

    /// Sticky messages (errors) stay until you tap a key or the mic.
    private func show(_ text: String, sticky: Bool = false) {
        message = text
        messageTimer?.invalidate()
        guard !sticky else { return }
        messageTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.message = nil }
        }
    }

    // MARK: Dictation

    var isRecording: Bool { state.phase == .recording }
    var isWorking: Bool { state.phase == .transcribing || state.phase == .polishing }

    func micTapped() {
        refreshState()
        message = nil
        if isRecording {
            stop()
        } else if !isWorking {
            start(mode: hasSelection ? .command : .dictation)
        }
    }

    func commandTapped() {
        refreshState()
        message = nil
        if isRecording { stop() } else if !isWorking { start(mode: .command) }
    }

    private func start(mode: DictationMode) {
        guard hasFullAccess else {
            show("Turn on Allow Full Access: Settings › General › Keyboard › Keyboards › Wispen.", sticky: true)
            return
        }
        let request = FlowRequest(action: .start, mode: mode, styleID: styleID,
                                  selectedText: mode == .command ? proxy?.selectedText : nil)
        do {
            try FlowIPC.requestFile.save(request)
        } catch {
            show("Couldn't reach the Wispen app. Is Allow Full Access on?", sticky: true)
            return
        }
        lightHaptic()
        waitingSince = Date()
        if state.isAlive() {
            DarwinNotifier.shared.post(.request)
        } else {
            controller?.openURL(FlowIPC.startURL(requestID: request.id))
        }
    }

    private func stop() {
        guard let current = FlowIPC.requestFile.load(), current.action == .start else { return }
        var stop = current
        stop.action = .stop
        stop.date = Date()
        try? FlowIPC.requestFile.save(stop)
        DarwinNotifier.shared.post(.request)
        lightHaptic()
    }

    func cancel() {
        waitingSince = nil
        guard let current = FlowIPC.requestFile.load() else { return }
        var cancel = current
        cancel.action = .cancel
        cancel.date = Date()
        try? FlowIPC.requestFile.save(cancel)
        DarwinNotifier.shared.post(.request)
    }

    /// Insert the finished text for our request, exactly once.
    func consumeResult() {
        guard isVisible, let result = FlowIPC.resultFile.load(),
              let request = FlowIPC.requestFile.load(), request.id == result.requestID,
              defaults.string(forKey: "lastConsumedResult") != result.requestID,
              Date().timeIntervalSince(result.date) < 300 else { return }
        defaults.set(result.requestID, forKey: "lastConsumedResult")
        waitingSince = nil

        if let error = result.error {
            show(error, sticky: true)
            return
        }
        guard let proxy, !result.text.isEmpty else { return }
        let selected = proxy.selectedText
        let text: String
        if result.mode == .command, let selected, !selected.isEmpty {
            text = result.text // replaces the selection as-is
        } else {
            text = InsertionFormatter.prepare(result.text, before: proxy.documentContextBeforeInput,
                                              after: proxy.documentContextAfterInput, protectedTerms: protectedTerms)
        }
        insertVerified(text, replacing: result.mode == .command ? selected : nil)
    }

    /// Types `text`, then checks it really landed. If the host app didn't take it, keep it and show
    /// an Insert button instead of losing the dictation.
    private func insertVerified(_ text: String, replacing selected: String?) {
        guard let proxy else { pendingInsert = text; return }
        let before = proxy.documentContextBeforeInput
        proxy.insertText(text)
        lastInsertion = (text, selected)
        lastAutocorrect = nil
        canUndo = true
        pendingInsert = nil
        successHaptic()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, let proxy = self.proxy else { return }
            let after = proxy.documentContextBeforeInput
            // nil means the app doesn't share its text (e.g. some web fields): assume it worked.
            if let after, after == before, !after.hasSuffix(text.trimmingCharacters(in: .whitespaces)) {
                self.pendingInsert = text
                self.canUndo = false
                self.lastInsertion = nil
            }
            self.refreshContext()
        }
    }

    /// The toolbar's Insert button for a dictation that didn't go in automatically.
    func insertPending() {
        guard let text = pendingInsert else { return }
        pendingInsert = nil
        insertVerified(text, replacing: nil)
    }

    func undo() {
        guard let last = lastInsertion, let proxy else { return }
        for _ in 0..<last.text.count { proxy.deleteBackward() }
        if let original = last.replaced { proxy.insertText(original) }
        lastInsertion = nil
        canUndo = false
        refreshContext()
    }

    // MARK: Typing

    func keyDown() {
        if settings.keyboardHaptics { lightHaptic() }
        if settings.keyboardSounds, hasFullAccess { AudioServicesPlaySystemSound(1104) }
    }

    func type(_ character: String) {
        message = nil
        pendingInsert = nil
        let text = (layer == .letters && shift != .off) ? character.uppercased() : character
        proxy?.insertText(text)
        afterEdit()
        if shift == .once { shift = .off }
        // Like the system keyboard: an apostrophe on the numbers layer returns to letters.
        if layer != .letters, character == "'" { layer = .letters }
        updateSuggestions()
    }

    func space() {
        guard let proxy else { return }
        let before = proxy.documentContextBeforeInput
        if settings.keyboardDoubleSpacePeriod, lastAutocorrect == nil,
           KeyboardTextLogic.shouldInsertDoubleSpacePeriod(before: before) {
            proxy.deleteBackward()
            proxy.insertText(". ")
            afterEdit()
        } else {
            let corrected = settings.keyboardAutoCorrect ? autocorrectCurrentWord() : nil
            proxy.insertText(" ")
            afterEdit()
            lastAutocorrect = corrected
        }
        if layer != .letters { layer = .letters }
        updateShift()
        updateSuggestions()
    }

    func newline() {
        proxy?.insertText("\n")
        afterEdit()
        updateShift()
        updateSuggestions()
    }

    func deleteBackward() {
        guard let proxy else { return }
        if let auto = lastAutocorrect {
            // Backspace right after an autocorrection restores what you typed.
            for _ in 0..<(auto.corrected.count + 1) { proxy.deleteBackward() }
            proxy.insertText(auto.original)
            lastAutocorrect = nil
        } else {
            proxy.deleteBackward()
        }
        canUndo = false
        updateShift()
        updateSuggestions()
    }

    /// Deletes the previous word (used when delete is held for a while).
    func deleteWordBackward() {
        guard let proxy else { return }
        let chars = Array(proxy.documentContextBeforeInput ?? "")
        var i = chars.count
        while i > 0, chars[i - 1].isWhitespace { i -= 1 } // trailing spaces…
        while i > 0, !chars[i - 1].isWhitespace { i -= 1 } // …then the word
        for _ in 0..<max(1, chars.count - i) { proxy.deleteBackward() }
        lastAutocorrect = nil
        updateShift()
        updateSuggestions()
    }

    func moveCursor(by offset: Int) {
        proxy?.adjustTextPosition(byCharacterOffset: offset)
        lastAutocorrect = nil
        updateSuggestions()
    }

    func shiftTapped() {
        let now = Date()
        if now.timeIntervalSince(lastShiftTap) < 0.3 {
            shift = .locked
        } else {
            shift = shift == .off ? .once : .off
        }
        lastShiftTap = now
    }

    func toggleLayer() {
        layer = layer == .letters ? .numbers : .letters
    }

    func toggleSymbols() {
        layer = layer == .symbols ? .numbers : .symbols
    }

    func pick(_ suggestion: String) {
        guard let proxy else { return }
        for _ in 0..<currentWord.count { proxy.deleteBackward() }
        proxy.insertText(suggestion + " ")
        lastAutocorrect = nil
        afterEdit()
        updateShift()
        updateSuggestions()
    }

    private func afterEdit() {
        canUndo = false
        if lastAutocorrect != nil { lastAutocorrect = nil }
    }

    private func updateShift() {
        guard shift != .locked else { return }
        guard settings.keyboardAutoCapitalize else { if shift == .once { shift = .off }; return }
        let mode: KeyboardTextLogic.Capitalization
        switch proxy?.autocapitalizationType ?? .sentences {
        case .none: mode = .none
        case .words: mode = .words
        case .allCharacters: mode = .allCharacters
        default: mode = .sentences
        }
        shift = KeyboardTextLogic.shouldCapitalize(before: proxy?.documentContextBeforeInput, mode: mode) ? .once : .off
    }

    private func updateSuggestions() {
        let word = KeyboardTextLogic.currentWord(before: proxy?.documentContextBeforeInput)
        currentWord = word
        guard settings.keyboardSuggestions, !word.isEmpty, word.count < 40 else {
            suggestions = []
            return
        }
        let range = NSRange(location: 0, length: (word as NSString).length)
        let misspelled = checker.rangeOfMisspelledWord(in: word, range: range, startingAt: 0, wrap: false,
                                                       language: checkerLanguage).location != NSNotFound
        let corrections = misspelled ? (checker.guesses(forWordRange: range, in: word, language: checkerLanguage) ?? []) : []
        let completions = checker.completions(forPartialWordRange: range, in: word, language: checkerLanguage) ?? []
        suggestions = KeyboardTextLogic.suggestions(for: word, vocabulary: protectedTerms, corrections: corrections,
                                                    completions: completions)
    }

    /// Fixes an obvious typo in the word before the cursor. Returns what was changed, for undo.
    private func autocorrectCurrentWord() -> (original: String, corrected: String)? {
        guard let proxy else { return nil }
        let word = KeyboardTextLogic.currentWord(before: proxy.documentContextBeforeInput)
        guard word.count >= 3 else { return nil }
        let range = NSRange(location: 0, length: (word as NSString).length)
        guard checker.rangeOfMisspelledWord(in: word, range: range, startingAt: 0, wrap: false,
                                            language: checkerLanguage).location != NSNotFound else { return nil }
        let guesses = checker.guesses(forWordRange: range, in: word, language: checkerLanguage) ?? []
        guard let fix = KeyboardTextLogic.autocorrection(for: word, guesses: guesses, protectedTerms: Set(protectedTerms)) else {
            return nil
        }
        for _ in 0..<word.count { proxy.deleteBackward() }
        proxy.insertText(fix)
        return (word, fix)
    }

    private static func label(for type: UIReturnKeyType?) -> String? {
        guard let type else { return nil }
        switch type {
        case .go: return "go"
        case .google, .search, .yahoo: return "search"
        case .join: return "join"
        case .next: return "next"
        case .route: return "route"
        case .send: return "send"
        case .done: return "done"
        case .continue: return "continue"
        case .emergencyCall: return "call"
        default: return nil
        }
    }

    // MARK: Haptics (only work with Full Access)

    private func lightHaptic() {
        guard hasFullAccess else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func successHaptic() {
        guard hasFullAccess else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}
