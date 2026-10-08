import Foundation
import WispenCore

/// Record → transcribe (Whisper) → polish (LLM) for one dictation. Used by the iOS flow session,
/// the in-app "Try it" box and the Mac hotkey.
@MainActor
final class DictationEngine: ObservableObject {
    enum Phase: Equatable {
        case idle, recording, transcribing, polishing
    }

    struct Outcome {
        var text: String
        var raw: String
        var error: String?
        var usedAI: Bool
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var level: Float = 0
    @Published private(set) var recordingStartedAt: Date?

    /// iOS flow sessions keep the microphone running between dictations (that's what keeps the app
    /// alive in the background). On macOS the mic only runs while you hold the key.
    var keepsMicWarm = false

    let app: AppModel
    let capture = AudioCapture()
    private let buffer = SampleBuffer()
    private var lastLevelUpdate = Date.distantPast

    init(app: AppModel) {
        self.app = app
        capture.onSamples = { [buffer] samples in buffer.append(samples) }
        capture.onLevel = { [weak self] level in
            Task { @MainActor in self?.updateLevel(level) }
        }
    }

    private func updateLevel(_ value: Float) {
        guard phase == .recording else { if level != 0 { level = 0 }; return }
        let now = Date()
        guard now.timeIntervalSince(lastLevelUpdate) > 0.05 else { return }
        lastLevelUpdate = now
        level = value
    }

    func warmUp() throws {
        if !capture.isRunning { try capture.start() }
    }

    struct BusyError: LocalizedError {
        var errorDescription: String? { "Still finishing the last dictation — try again in a moment." }
    }

    func startRecording() throws {
        if phase == .recording { return }
        guard phase == .idle else { throw BusyError() }
        try warmUp()
        buffer.begin()
        recordingStartedAt = Date()
        phase = .recording
    }

    func cancel() {
        _ = buffer.end()
        phase = .idle
        recordingStartedAt = nil
        if !keepsMicWarm { capture.stop() }
    }

    func coolDown() {
        _ = buffer.end()
        capture.stop()
        phase = .idle
    }

    /// Stops recording and returns the finished text.
    func finish(mode: DictationMode, styleID: String, selectedText: String? = nil, appName: String? = nil) async -> Outcome {
        guard phase == .recording else { return Outcome(text: "", raw: "", error: "Not recording.", usedAI: false) }
        let samples = buffer.end()
        if !keepsMicWarm { capture.stop() }
        recordingStartedAt = nil
        level = 0
        defer { phase = .idle }

        let duration = Double(samples.count) / AudioMath.sampleRate
        guard duration > 0.3, AudioMath.containsSpeech(samples) else {
            return Outcome(text: "", raw: "", error: "No speech detected.", usedAI: false)
        }

        phase = .transcribing
        let raw: String
        do {
            raw = try await app.transcribe(samples)
        } catch {
            return Outcome(text: "", raw: "", error: error.localizedDescription, usedAI: false)
        }

        phase = .polishing
        var outcome: Outcome
        switch mode {
        case .dictation:
            let result = await CleanupPipeline(generator: app.generator)
                .clean(raw, context: app.cleanupContext(styleID: styleID, appName: appName))
            outcome = Outcome(text: result.text, raw: raw, error: result.text.isEmpty ? "No speech detected." : nil,
                              usedAI: result.usedAI)
        case .command:
            do {
                let text = try await CommandProcessor(generator: app.generator)
                    .run(instruction: raw, selectedText: selectedText, dictionary: app.dictionary)
                outcome = Outcome(text: text, raw: raw, error: nil, usedAI: true)
            } catch {
                outcome = Outcome(text: "", raw: raw, error: error.localizedDescription, usedAI: false)
            }
        }

        if outcome.error == nil {
            app.addHistory(HistoryItem(mode: mode, raw: raw, output: outcome.text, styleID: styleID,
                                       durationSeconds: duration, usedAI: outcome.usedAI, appName: appName))
        }
        return outcome
    }
}
