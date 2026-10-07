import SwiftUI
import UIKit
import WispenCore

@MainActor
final class KeyboardModel: ObservableObject {
    @Published var state: FlowSessionState = .inactive
    @Published var styleID: String
    @Published var hasSelection = false
    @Published var message: String?
    @Published var canUndo = false
    /// Set between tapping the mic and the app confirming it's recording.
    @Published private var waitingSince: Date?

    let styles: [DictationStyle]
    private let store = WispenStore()
    private weak var controller: KeyboardViewController?
    private var poll: Timer?
    private var lastInsertion: (text: String, replaced: String?)?
    private let defaults = UserDefaults.standard
    private let protectedTerms: [String]

    init(controller: KeyboardViewController) {
        self.controller = controller
        styles = store.allStyles()
        protectedTerms = store.loadDictionary().map(\.term)
        let settings = store.loadSettings()
        styleID = UserDefaults.standard.string(forKey: "keyboardStyleID") ?? settings.defaultStyleID

        DarwinNotifier.shared.observe(.state) { [weak self] in Task { @MainActor in self?.refreshState() } }
        DarwinNotifier.shared.observe(.result) { [weak self] in Task { @MainActor in self?.consumeResult() } }
    }

    var waitingForApp: Bool {
        guard let since = waitingSince else { return false }
        return Date().timeIntervalSince(since) < 10
    }

    var proxy: UITextDocumentProxy? { controller?.textDocumentProxy }
    var hasFullAccess: Bool { controller?.hasFullAccess ?? false }
    var needsGlobeKey: Bool { controller?.needsInputModeSwitchKey ?? true }
    var style: DictationStyle { styles.first { $0.id == styleID } ?? .polished }

    func selectStyle(_ id: String) {
        styleID = id
        defaults.set(id, forKey: "keyboardStyleID")
    }

    // MARK: Lifecycle

    func appeared() {
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

    func disappeared() {
        poll?.invalidate()
        poll = nil
    }

    func refreshContext() {
        hasSelection = !(proxy?.selectedText ?? "").isEmpty
    }

    func refreshState() {
        guard let s = FlowIPC.stateFile.load() else {
            state = .inactive
            return
        }
        state = s.isAlive() ? s : .inactive
        if state.phase == .recording || state.phase == .error { waitingSince = nil }
        if state.phase == .error, let m = state.message { message = m }
    }

    // MARK: Actions

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
            message = "Turn on Allow Full Access: Settings › General › Keyboard › Keyboards › Wispen."
            return
        }
        let request = FlowRequest(action: .start, mode: mode, styleID: styleID,
                                  selectedText: mode == .command ? proxy?.selectedText : nil)
        do {
            try FlowIPC.requestFile.save(request)
        } catch {
            message = "Couldn't reach the Wispen app. Is Allow Full Access on?"
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
        guard let result = FlowIPC.resultFile.load(),
              let request = FlowIPC.requestFile.load(), request.id == result.requestID,
              defaults.string(forKey: "lastConsumedResult") != result.requestID,
              Date().timeIntervalSince(result.date) < 300 else { return }
        defaults.set(result.requestID, forKey: "lastConsumedResult")
        waitingSince = nil

        if let error = result.error {
            message = error
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
        proxy.insertText(text)
        lastInsertion = (text, result.mode == .command ? selected : nil)
        canUndo = true
        successHaptic()
    }

    func undo() {
        guard let last = lastInsertion, let proxy else { return }
        for _ in 0..<last.text.count { proxy.deleteBackward() }
        if let original = last.replaced { proxy.insertText(original) }
        lastInsertion = nil
        canUndo = false
    }

    // MARK: Basic keys

    func insert(_ s: String) {
        proxy?.insertText(s)
        canUndo = false
    }

    func deleteBackward() {
        proxy?.deleteBackward()
        canUndo = false
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
