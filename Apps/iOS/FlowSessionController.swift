import Combine
import Foundation
import UIKit
import WispenCore

/// Runs the background "flow session" that lets the Wispen keyboard dictate into any app.
///
/// iOS keyboards can't use the microphone, so the keyboard opens Wispen once, Wispen starts its
/// audio engine (which keeps it running in the background, with the orange mic dot), and you swipe
/// back. From then on the keyboard sends start/stop requests over Darwin notifications and the
/// app streams results back — until the session times out.
@MainActor
final class FlowSessionController: ObservableObject {
    @Published private(set) var state: FlowSessionState = .inactive
    /// Shown after the keyboard opened Wispen: "Swipe back to keep talking".
    @Published var showSwipeBackHint = false
    @Published private(set) var lastError: String?

    let app: AppModel
    let engine: DictationEngine
    private var heartbeat: Timer?
    private var idleDeadline = Date.distantFuture
    private var current: FlowRequest?
    private var handled: Set<String> = []
    private var bag: Set<AnyCancellable> = []

    init(app: AppModel) {
        self.app = app
        self.engine = DictationEngine(app: app)
        engine.keepsMicWarm = true
        DarwinNotifier.shared.observe(.request) { [weak self] in
            Task { @MainActor in self?.handlePendingRequest() }
        }
        engine.$phase
            .sink { [weak self] phase in self?.engineChanged(phase) }
            .store(in: &bag)
        // Locking the phone ends the session: no reason to keep the mic ready in your pocket.
        NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)
            .sink { [weak self] _ in self?.phoneLocked() }
            .store(in: &bag)
        // A previous run may have died with a stale "alive" state; clear it, and remember why it ended.
        let previous = FlowIPC.stateFile.load()
        if let previous, previous.phase != .inactive {
            lastEndReason = "iOS closed Wispen in the background"
            lastEndedAt = previous.heartbeat
        } else {
            lastEndReason = previous?.endReason
            lastEndedAt = previous?.endReason == nil ? nil : previous?.heartbeat
        }
        engine.capture.onInterrupted = { [weak self] in
            Task { @MainActor in self?.micInterrupted() }
        }
        publish(.inactive)
    }

    /// Why the last session ended and when, shown on the Flow tab.
    @Published private(set) var lastEndReason: String?
    @Published private(set) var lastEndedAt: Date?

    var isActive: Bool { state.phase != .inactive }

    // MARK: Session lifecycle

    func startSession() async {
        guard !isActive else { bumpIdle(); return }
        guard await AudioCapture.requestPermission() else {
            fail(AudioCaptureError.permissionDenied.localizedDescription)
            return
        }
        do {
            try engine.warmUp()
        } catch {
            fail(error.localizedDescription)
            return
        }
        bumpIdle()
        publish(.ready)
        heartbeat?.invalidate()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // Load Whisper now so the first dictation is fast.
        Task { await app.prepareSpeechModel() }
    }

    func endSession(reason: String = "You ended it") {
        heartbeat?.invalidate()
        heartbeat = nil
        if let current {
            try? FlowIPC.resultFile.save(FlowResult(requestID: current.id, mode: current.mode, text: "", error: reason))
            DarwinNotifier.shared.post(.result)
        }
        current = nil
        engine.coolDown()
        lastEndReason = reason
        lastEndedAt = Date()
        publish(.inactive)
    }

    /// A call, Siri, the camera or another recording app took the microphone.
    private func micInterrupted() {
        guard isActive else { return }
        // iOS hands the microphone back when the interruption ends; check again shortly.
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            self.checkMic()
        }
    }

    /// Keep the microphone running, which is what keeps Wispen alive in the background.
    private func checkMic() {
        guard isActive, !engine.capture.isLive else { return }
        do {
            try engine.capture.ensureLive()
        } catch {
            endSession(reason: "Another app took the microphone (a call, the camera or a recorder)")
        }
    }

    private var endAfterCurrentDictation = false

    private func phoneLocked() {
        guard isActive else { return }
        if state.phase == .ready || state.phase == .error {
            endSession(reason: "Phone locked")
        } else {
            endAfterCurrentDictation = true // finish what you were saying first
        }
    }

    private func tick() {
        if state.phase == .ready, Date() > idleDeadline {
            endSession(reason: "No dictation for \(app.settings.sessionTimeoutMinutes) minutes")
            return
        }
        checkMic()
        publish(state.phase, message: state.message)
    }

    private func bumpIdle() {
        let minutes = app.settings.sessionTimeoutMinutes
        idleDeadline = minutes <= 0 ? .distantFuture : Date().addingTimeInterval(TimeInterval(minutes * 60))
    }

    // MARK: Requests from the keyboard

    /// Opened via `wispen://flow?request=<id>` from the keyboard.
    func handle(url: URL) {
        guard url.scheme == FlowIPC.urlScheme, url.host == "flow" else { return }
        showSwipeBackHint = true
        Task {
            await startSession()
            handlePendingRequest()
        }
    }

    /// Tell the keyboard we can't serve its request right now (e.g. a meeting is using the mic).
    func reject(url: URL, reason: String) {
        guard url.scheme == FlowIPC.urlScheme, let request = FlowIPC.requestFile.load() else { return }
        try? FlowIPC.resultFile.save(FlowResult(requestID: request.id, mode: request.mode, text: "", error: reason))
        DarwinNotifier.shared.post(.result)
    }

    func handlePendingRequest() {
        guard let request = FlowIPC.requestFile.load() else { return }
        let key = "\(request.id):\(request.action.rawValue)"
        // Ignore stale requests (e.g. one left over from yesterday) and ones we've already served.
        guard !handled.contains(key), Date().timeIntervalSince(request.date) < 120 else { return }
        handled.insert(key)

        switch request.action {
        case .start:
            Task { await start(request) }
        case .stop:
            guard let current, current.id == request.id else { return }
            Task { await finish(current) }
        case .cancel:
            engine.cancel()
            current = nil
            publish(.ready)
        }
    }

    private func start(_ request: FlowRequest) async {
        if !isActive { await startSession() }
        guard isActive else { return }
        do {
            try engine.startRecording()
            current = request
            bumpIdle()
            publish(.recording, mode: request.mode, requestID: request.id)
        } catch {
            // Tell the keyboard right away instead of leaving it waiting.
            try? FlowIPC.resultFile.save(FlowResult(requestID: request.id, mode: request.mode, text: "",
                                                    error: error.localizedDescription))
            DarwinNotifier.shared.post(.result)
            lastError = error.localizedDescription
            publish(.ready)
        }
    }

    private func finish(_ request: FlowRequest) async {
        let outcome = await engine.finish(mode: request.mode, styleID: request.styleID, selectedText: request.selectedText)
        current = nil
        bumpIdle()
        try? FlowIPC.resultFile.save(FlowResult(requestID: request.id, mode: request.mode, text: outcome.text, error: outcome.error))
        DarwinNotifier.shared.post(.result)
        NotificationCenter.default.post(name: .wispenResultWritten, object: nil)
        publish(.ready)
        if endAfterCurrentDictation {
            endAfterCurrentDictation = false
            endSession(reason: "Phone locked")
        }
    }

    /// In-app dictation (Home screen "Try it" box). Shares the same engine.
    func dictateInApp(start: Bool, styleID: String) async -> String? {
        if start {
            if !isActive { await startSession() }
            try? engine.startRecording()
            publish(.recording)
            return nil
        }
        let outcome = await engine.finish(mode: .dictation, styleID: styleID)
        publish(.ready)
        if let error = outcome.error { lastError = error }
        return outcome.text.isEmpty ? nil : outcome.text
    }

    // MARK: State publishing

    private func engineChanged(_ phase: DictationEngine.Phase) {
        guard isActive else { return }
        switch phase {
        case .transcribing:
            publish(.transcribing, mode: current?.mode ?? .dictation, requestID: current?.id,
                    message: app.speechModel.isReady ? nil : "Loading the speech model…")
        case .polishing: publish(.polishing, mode: current?.mode ?? .dictation, requestID: current?.id)
        default: break
        }
    }

    private func fail(_ message: String) {
        lastError = message
        publish(.error, message: message)
        // Keep the keyboard from waiting forever.
        if let current {
            try? FlowIPC.resultFile.save(FlowResult(requestID: current.id, mode: current.mode, text: "", error: message))
            DarwinNotifier.shared.post(.result)
            self.current = nil
        }
    }

    private func publish(_ phase: FlowSessionState.Phase, mode: DictationMode? = nil, requestID: String? = nil, message: String? = nil) {
        state = FlowSessionState(
            phase: phase,
            mode: mode ?? state.mode,
            requestID: requestID ?? (phase == .ready || phase == .inactive ? nil : state.requestID),
            message: message,
            heartbeat: Date(),
            sessionEndsAt: phase == .inactive || idleDeadline == .distantFuture ? nil : idleDeadline,
            endReason: phase == .inactive ? lastEndReason : nil)
        try? FlowIPC.stateFile.save(state)
        DarwinNotifier.shared.post(.state)
        LiveActivityController.shared.updateFlow(state, recordingStartedAt: engine.recordingStartedAt)
    }
}
