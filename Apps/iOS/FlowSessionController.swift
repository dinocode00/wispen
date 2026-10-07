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
        // A previous run may have died with a stale "alive" state; clear it.
        publish(.inactive)
    }

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

    func endSession() {
        heartbeat?.invalidate()
        heartbeat = nil
        current = nil
        engine.coolDown()
        publish(.inactive)
    }

    private func tick() {
        if state.phase == .ready, Date() > idleDeadline {
            endSession()
            return
        }
        publish(state.phase, message: state.message)
    }

    private func bumpIdle() {
        idleDeadline = Date().addingTimeInterval(TimeInterval(max(1, app.settings.sessionTimeoutMinutes) * 60))
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
            fail(error.localizedDescription)
        }
    }

    private func finish(_ request: FlowRequest) async {
        let outcome = await engine.finish(mode: request.mode, styleID: request.styleID, selectedText: request.selectedText)
        current = nil
        bumpIdle()
        try? FlowIPC.resultFile.save(FlowResult(requestID: request.id, mode: request.mode, text: outcome.text, error: outcome.error))
        DarwinNotifier.shared.post(.result)
        publish(.ready)
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
        case .transcribing: publish(.transcribing, mode: current?.mode ?? .dictation, requestID: current?.id)
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
            sessionEndsAt: phase == .inactive ? nil : idleDeadline)
        try? FlowIPC.stateFile.save(state)
        DarwinNotifier.shared.post(.state)
    }
}
