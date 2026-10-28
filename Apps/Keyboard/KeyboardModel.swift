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
    /// Emoji for the current word ("cool" → 😎), offered next to the word suggestions.
    @Published private(set) var emojiSuggestions: [String] = []
    /// A snippet whose keyboard shortcut was just typed: tap to type the whole thing.
    @Published private(set) var shortcutSuggestion: Snippet?
    /// What space will change the current word to (shown bold in the suggestion bar).
    @Published private(set) var autocorrectPreview: String?
    @Published var currentWord = ""
    @Published var showStyles = false
    @Published var showEmoji = false
    /// The space bar is held: the keyboard is a trackpad for the cursor.
    @Published private(set) var trackpadActive = false
    private var navigator: CursorNavigator?
    @Published private(set) var recentEmoji: [String] = UserDefaults.standard.stringArray(forKey: "recentEmoji") ?? []
    /// Slide across the letters to type a word (Wispen › Settings).
    private(set) var swipeTyping = true
    @Published private(set) var returnKeyLabel: String?

    let styles: [DictationStyle]
    private(set) var settings: WispenSettings
    /// Look and touch effects; changes in the Wispen app apply right away.
    @Published private(set) var theme: KeyboardTheme
    let effects = KeyEffectsEngine()
    let presses = KeyPressState()
    private let store = WispenStore()
    private weak var controller: KeyboardViewController?
    private var poll: Timer?
    private var messageTimer: Timer?
    private var lastInsertion: (text: String, replaced: String?)?
    private var lastAutocorrect: (original: String, corrected: String, trailing: String)?
    /// The word just typed by swiping, and the other likely words (offered in the suggestion bar).
    private var lastSwipe: (word: String, alternatives: [String])?
    private var autocorrector = Autocorrector(strength: .balanced)
    /// Words you've kept after Wispen corrected them: never corrected again.
    private var learnedWords: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "learnedWords") ?? [])
    private var lastShiftTap = Date.distantPast
    private let defaults = UserDefaults.standard
    private let protectedTerms: [String]
    /// Snippets with a keyboard shortcut (reloaded each time the keyboard appears).
    private var shortcutSnippets: [Snippet] = []
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
        autocorrector = Autocorrector(strength: settings.keyboardAutocorrectStrength)
        swipeTyping = settings.keyboardSwipeTyping
        // Build the swipe word index off the main thread, before the first swipe needs it.
        DispatchQueue.global(qos: .utility).async { _ = SwipeIndex.english; _ = EmojiSuggester.shared }
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

    /// The globe key: tap for the next keyboard, hold for the list.
    func handleInputModeList(from view: UIView, with event: UIEvent?) {
        guard let event else { return }
        controller?.handleInputModeList(from: view, with: event)
    }
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
        shortcutSnippets = store.loadSnippets().filter { $0.typedShortcut != nil }
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
        let fresh = store.loadSettings()
        if fresh.keyboardEmojiSuggestions != settings.keyboardEmojiSuggestions {
            settings.keyboardEmojiSuggestions = fresh.keyboardEmojiSuggestions
            updateSuggestions()
        }
        autocorrector.strength = fresh.keyboardAutocorrectStrength
        swipeTyping = fresh.keyboardSwipeTyping
        let t = fresh.keyboardTheme
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
        waitingSince = Date()
        let latest = FlowIPC.stateFile.load() ?? state
        if latest.isAlive() {
            DarwinNotifier.shared.post(.request)
        } else if latest.mightBeAlive() {
            // Wispen reported in recently: give it a moment to answer before opening it.
            DarwinNotifier.shared.post(.request)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                guard let self else { return }
                self.refreshState()
                if !self.state.isAlive() {
                    self.controller?.openURL(FlowIPC.startURL(requestID: request.id))
                }
            }
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
        if settings.keyboardSounds, hasFullAccess { AudioServicesPlaySystemSound(1104) }
    }

    func type(_ character: String) {
        message = nil
        pendingInsert = nil
        let text = (layer == .letters && shift != .off) ? character.uppercased() : character
        // Punctuation ends a word, so it's corrected first (like space).
        let corrected = ".,!?;:".contains(character) ? autocorrectCurrentWord() : nil
        proxy?.insertText(text)
        afterEdit()
        if let corrected { lastAutocorrect = (corrected.original, corrected.corrected, text) }
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
            let corrected = autocorrectCurrentWord()
            proxy.insertText(" ")
            afterEdit()
            lastAutocorrect = corrected.map { ($0.original, $0.corrected, " ") }
        }
        if layer != .letters { layer = .letters }
        updateShift()
        updateSuggestions()
    }

    func newline() {
        let corrected = autocorrectCurrentWord()
        proxy?.insertText("\n")
        afterEdit()
        lastAutocorrect = corrected.map { ($0.original, $0.corrected, "\n") }
        updateShift()
        updateSuggestions()
    }

    func deleteBackward() {
        guard let proxy else { return }
        if let auto = lastAutocorrect {
            // Backspace right after an autocorrection restores what you typed, and remembers it.
            for _ in 0..<(auto.corrected.count + auto.trailing.count) { proxy.deleteBackward() }
            proxy.insertText(auto.original)
            learn(auto.original)
            lastAutocorrect = nil
        } else if let swipe = lastSwipe, currentWord == swipe.word,
                  proxy.documentContextBeforeInput?.hasSuffix(swipe.word) == true {
            // Like the system keyboard: backspace after a swipe removes the whole word.
            for _ in 0..<swipe.word.count { proxy.deleteBackward() }
            lastSwipe = nil
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

    // MARK: Space-bar trackpad

    /// Takes a snapshot of the text around the cursor to move through (the text iOS reports lags
    /// behind cursor moves, so it isn't re-read while the trackpad is in use).
    func beginTrackpad() {
        guard let proxy else { return }
        navigator = CursorNavigator(before: proxy.documentContextBeforeInput ?? "",
                                    after: proxy.documentContextAfterInput ?? "",
                                    lineWidth: estimatedLineWidth)
        lastAutocorrect = nil
        lastSwipe = nil
        withAnimation(.easeOut(duration: 0.2)) { trackpadActive = true }
    }

    /// Moves the cursor sideways by characters and up or down by lines.
    func trackpadMove(characters: Int, lines: Int) {
        guard var nav = navigator else { return }
        let offset = nav.move(characters: characters, lines: lines)
        navigator = nav
        if offset != 0 { proxy?.adjustTextPosition(byCharacterOffset: offset) }
    }

    func endTrackpad() {
        navigator = nil
        withAnimation(.easeOut(duration: 0.2)) { trackpadActive = false }
        updateShift()
        updateSuggestions()
    }

    /// About how many characters fit on a line in the app (it can't tell the keyboard): the
    /// screen width at a typical 17-point text size.
    private var estimatedLineWidth: Int {
        let width = controller?.view.bounds.width ?? 390
        return max(20, Int((width - 32) / 8.4))
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
        // Tapping your own spelling (“…”) keeps it, and teaches the keyboard the word.
        if suggestion == currentWord, autocorrectPreview != nil { learn(suggestion) }
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
        lastSwipe = nil
    }

    // MARK: Swipe typing and emoji

    /// Your dictionary and learned words can be swiped too.
    var swipeExtraWords: [String] { protectedTerms + Array(learnedWords) }

    /// Types the best of `words` (likeliest first) for a swipe. The others show above the keys.
    func swiped(_ words: [String]) {
        guard let proxy, !words.isEmpty else { return }
        message = nil
        pendingInsert = nil
        // A word you were tapping out is finished first, as if you'd pressed space.
        if lastSwipe == nil { _ = autocorrectCurrentWord() }
        let cased = words.map { w -> String in
            switch shift {
            case .locked: return w.uppercased()
            case .once: return w.prefix(1).uppercased() + w.dropFirst()
            case .off: return w
            }
        }
        // Words are spaced automatically, so you can swipe one after another.
        let before = proxy.documentContextBeforeInput ?? ""
        let needsSpace = before.last.map { !$0.isWhitespace && !"([{\"“‘/@#-".contains($0) } ?? false
        proxy.insertText((needsSpace ? " " : "") + cased[0])
        afterEdit()
        lastSwipe = (cased[0], Array(cased.dropFirst()))
        if shift == .once { shift = .off }
        updateSuggestions()
    }

    func insertEmoji(_ emoji: String) {
        message = nil
        pendingInsert = nil
        proxy?.insertText(emoji)
        afterEdit()
        recentEmoji = EmojiCatalog.recordUse(emoji, in: recentEmoji)
        defaults.set(recentEmoji, forKey: "recentEmoji")
        updateShift()
        updateSuggestions()
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

    /// Types the snippet in place of its shortcut.
    func pickShortcut(_ snippet: Snippet) {
        guard let proxy, let shortcut = snippet.typedShortcut else { return }
        for _ in 0..<shortcut.count { proxy.deleteBackward() }
        let text = snippet.expansion
        proxy.insertText(text.last?.isWhitespace == true ? text : text + " ")
        afterEdit()
        updateShift()
        updateSuggestions()
    }

    /// Replaces the word with its emoji, like the iOS keyboard.
    func pickEmoji(_ emoji: String) {
        guard let proxy else { return }
        for _ in 0..<currentWord.count { proxy.deleteBackward() }
        proxy.insertText(emoji + " ")
        afterEdit()
        recentEmoji = EmojiCatalog.recordUse(emoji, in: recentEmoji)
        defaults.set(recentEmoji, forKey: "recentEmoji")
        updateShift()
        updateSuggestions()
    }

    private func updateSuggestions() {
        let before = proxy?.documentContextBeforeInput
        let word = KeyboardTextLogic.currentWord(before: before)
        currentWord = word
        shortcutSuggestion = TextShortcuts.match(before: before, in: shortcutSnippets)
        emojiSuggestions = settings.keyboardEmojiSuggestions && shortcutSuggestion == nil
            ? EmojiSuggester.shared.emoji(for: word) : []
        if let swipe = lastSwipe, swipe.word == word {
            autocorrectPreview = nil
            suggestions = Array(swipe.alternatives.prefix(2))
            return
        }
        guard settings.keyboardSuggestions, !word.isEmpty, word.count < 40 else {
            suggestions = []
            autocorrectPreview = nil
            return
        }
        let range = NSRange(location: 0, length: (word as NSString).length)
        let misspelled = checker.rangeOfMisspelledWord(in: word, range: range, startingAt: 0, wrap: false,
                                                       language: checkerLanguage).location != NSNotFound
        let corrections = misspelled ? (checker.guesses(forWordRange: range, in: word, language: checkerLanguage) ?? []) : []
        let completions = checker.completions(forPartialWordRange: range, in: word, language: checkerLanguage) ?? []
        let preview = autocorrector.correction(for: word, systemKnows: !misspelled, protected: protectedSet,
                                               extraCandidates: corrections)
        autocorrectPreview = preview
        let rest = KeyboardTextLogic.suggestions(for: word, vocabulary: protectedTerms, corrections: corrections,
                                                 completions: completions)
        suggestions = Array(([preview].compactMap { $0 } + rest.filter { $0 != preview }).prefix(2))
    }

    /// Your dictionary words plus words you've taught the keyboard, lowercased.
    private var protectedSet: Set<String> {
        Set((protectedTerms + shortcutSnippets.compactMap(\.typedShortcut)).map { $0.lowercased() }).union(learnedWords)
    }

    private func learn(_ word: String) {
        let lower = word.lowercased()
        guard !lower.isEmpty, !learnedWords.contains(lower) else { return }
        learnedWords.insert(lower)
        defaults.set(Array(learnedWords), forKey: "learnedWords")
        if !UITextChecker.hasLearnedWord(word) { UITextChecker.learnWord(word) }
    }

    /// Fixes a typo in the word before the cursor (strength set in Wispen › Settings). Returns what
    /// was changed, for undo.
    private func autocorrectCurrentWord() -> (original: String, corrected: String)? {
        guard let proxy, autocorrector.strength != .off else { return nil }
        let word = KeyboardTextLogic.currentWord(before: proxy.documentContextBeforeInput)
        guard !word.isEmpty, word.count < 30 else { return nil }
        // A swiped word is already a real word.
        if let swipe = lastSwipe, swipe.word == word { return nil }
        let range = NSRange(location: 0, length: (word as NSString).length)
        let misspelled = checker.rangeOfMisspelledWord(in: word, range: range, startingAt: 0, wrap: false,
                                                       language: checkerLanguage).location != NSNotFound
        let guesses = misspelled ? (checker.guesses(forWordRange: range, in: word, language: checkerLanguage) ?? []) : []
        guard let fix = autocorrector.correction(for: word, systemKnows: !misspelled, protected: protectedSet,
                                                 extraCandidates: guesses), fix != word else { return nil }
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
}
