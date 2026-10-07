import Foundation
import WispenCore
#if os(iOS)
import UIKit
#endif

/// Something that produces 16 kHz mono audio for a meeting: the microphone, or (macOS) system audio.
protocol MeetingAudioSource: AnyObject {
    /// Speaker label for segments from this source ("Me" / "Others"), or nil.
    var label: String? { get }
    var onSamples: (([Float]) -> Void)? { get set }
    var onLevel: ((Float) -> Void)? { get set }
    func start() async throws
    func stop()
}

final class MicrophoneSource: MeetingAudioSource {
    let label: String?
    private let capture = AudioCapture()

    init(label: String?) {
        self.label = label
    }

    var onSamples: (([Float]) -> Void)? {
        get { capture.onSamples }
        set { capture.onSamples = newValue }
    }

    var onLevel: ((Float) -> Void)? {
        get { capture.onLevel }
        set { capture.onLevel = newValue }
    }

    func start() async throws { try capture.start() }
    func stop() { capture.stop() }
}

/// Records a meeting, transcribing ~30-second chunks *while* recording. Each chunk's audio is
/// discarded as soon as it's transcribed — no audio is ever written to disk. When you stop, the
/// remaining audio is transcribed and the recap is generated.
@MainActor
final class MeetingRecorder: ObservableObject {
    @Published private(set) var meeting: Meeting?
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var level: Float = 0
    /// Chunks recorded but not yet transcribed.
    @Published private(set) var backlog = 0
    /// Recap progress (stage text and 0…1 fraction) while summarizing.
    @Published private(set) var recapStage: String?
    @Published private(set) var recapProgress: Double = 0
    @Published var errorMessage: String?

    private let app: AppModel
    private var sources: [MeetingAudioSource] = []
    private var chunkers: [ObjectIdentifier: LockedChunker] = [:]
    private var jobs: AsyncStream<Job>.Continuation?
    private var worker: Task<Void, Never>?
    private var clock: Timer?
    private var startedAt = Date()
    private var lastSave = Date()
    private var summarizing: Set<String> = []

    struct Job: Sendable {
        let label: String?
        let chunk: SpeechChunker.Chunk
    }

    init(app: AppModel) {
        self.app = app
    }

    /// - Parameter extraSources: e.g. system audio on macOS.
    func start(title: String = "", micLabel: String? = nil, extraSources: [MeetingAudioSource] = []) async {
        guard !isRecording else { return }
        errorMessage = nil
        guard await AudioCapture.requestPermission() else {
            errorMessage = AudioCaptureError.permissionDenied.localizedDescription
            return
        }
        await app.prepareSpeechModel()
        guard app.speechModel.isReady else {
            errorMessage = "The speech model isn't ready: \(app.speechModel.label)"
            return
        }

        let m = Meeting(title: title, startedAt: Date(), status: .recording)
        meeting = m
        app.save(m)
        startedAt = m.startedAt
        elapsed = 0
        backlog = 0

        let (stream, continuation) = AsyncStream<Job>.makeStream()
        jobs = continuation
        worker = Task { [weak self] in
            for await job in stream {
                await self?.transcribe(job)
            }
        }

        sources = [MicrophoneSource(label: micLabel)] + extraSources
        for source in sources {
            let chunker = LockedChunker()
            chunkers[ObjectIdentifier(source)] = chunker
            let label = source.label
            source.onSamples = { [weak self] samples in
                let ready = chunker.append(samples)
                guard !ready.isEmpty else { return }
                Task { @MainActor in
                    for chunk in ready { self?.enqueue(Job(label: label, chunk: chunk)) }
                }
            }
            if source.label != "Others" {
                source.onLevel = { [weak self] value in Task { @MainActor in self?.level = value } }
            }
            do {
                try await source.start()
            } catch {
                // System audio is optional; the mic is not.
                if source === sources.first {
                    errorMessage = error.localizedDescription
                    await cancelStart()
                    return
                }
                errorMessage = "Recording mic only: \(error.localizedDescription)"
            }
        }

        isRecording = true
        clock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.elapsed = Date().timeIntervalSince(self.startedAt)
            }
        }
    }

    private func cancelStart() async {
        sources.forEach { $0.stop() }
        sources.removeAll()
        jobs?.finish()
        await worker?.value
        if let m = meeting { app.deleteMeeting(m) }
        meeting = nil
    }

    private func enqueue(_ job: Job) {
        backlog += 1
        jobs?.yield(job)
    }

    private func transcribe(_ job: Job) async {
        defer { backlog = max(0, backlog - 1) }
        guard job.chunk.hasSpeech, var m = meeting else { return }
        do {
            let raw = try await app.transcribe(job.chunk.samples)
            var text = WhisperArtifactFilter.clean(raw)
            text = DictionaryApplier.apply(text, entries: app.dictionary)
            guard !text.isEmpty else { return }
            m = meeting ?? m
            let segment = TranscriptSegment(start: job.chunk.start, end: job.chunk.end, speaker: job.label, text: text)
            if job.label == "Me", TranscriptMerger.isMicEcho(segment, among: m.segments.filter { $0.speaker == "Others" }) {
                return
            }
            m.segments.append(segment)
            m.segments.sort { $0.start < $1.start }
            meeting = m
            // Save periodically so a crash never loses more than a minute of transcript.
            if Date().timeIntervalSince(lastSave) > 60 {
                lastSave = Date()
                app.save(m)
            }
        } catch {
            errorMessage = "Transcription error: \(error.localizedDescription)"
        }
    }

    /// Stops recording, finishes transcription, then writes the recap.
    func stop() async {
        guard isRecording, var m = meeting else { return }
        isRecording = false
        clock?.invalidate()
        clock = nil
        level = 0
        for source in sources {
            source.stop()
            if let rest = chunkers[ObjectIdentifier(source)]?.flush() {
                enqueue(Job(label: source.label, chunk: rest))
            }
        }
        sources.removeAll()
        chunkers.removeAll()

        let background = beginBackgroundWork()
        defer { endBackgroundWork(background) }

        recapStage = "Finishing transcript…"
        jobs?.finish()
        await worker?.value
        worker = nil
        jobs = nil

        m = meeting ?? m
        m.duration = Date().timeIntervalSince(m.startedAt)
        m.status = .needsRecap
        meeting = m
        app.save(m)
        await summarize(meetingID: m.id)
        meeting = nil
    }

    /// Generates (or regenerates) the recap for a saved meeting.
    func summarize(meetingID: String) async {
        guard !summarizing.contains(meetingID), var m = app.meetings.first(where: { $0.id == meetingID }) else { return }
        summarizing.insert(meetingID)
        defer { summarizing.remove(meetingID) }
        guard !m.segments.isEmpty else {
            m.status = .ready
            m.errorMessage = "No speech was captured."
            app.save(m)
            recapStage = nil
            return
        }
        guard let generator = app.generator, await generator.isAvailable else {
            m.status = .needsRecap
            m.errorMessage = "Recaps need Apple Intelligence (or Ollama on Mac). The full transcript is saved — "
                + "tap “Generate recap” once it's available."
            app.save(m)
            recapStage = nil
            return
        }

        let background = beginBackgroundWork()
        defer { endBackgroundWork(background) }

        m.status = .summarizing
        m.errorMessage = nil
        app.save(m)
        recapStage = "Reading transcript…"
        recapProgress = 0
        do {
            let recap = try await MeetingSummarizer(generator: generator).summarize(transcript: m.transcriptText) { done, total, stage in
                Task { @MainActor [weak self] in
                    self?.recapStage = stage
                    self?.recapProgress = total > 0 ? Double(done) / Double(total) : 0
                }
            }
            // Keep checkbox state from a previous recap when regenerating.
            m = app.meetings.first(where: { $0.id == meetingID }) ?? m
            m.recap = recap
            if m.title.isEmpty { m.title = recap.title }
            m.status = .ready
        } catch {
            m.status = .failed
            m.errorMessage = error.localizedDescription
        }
        app.save(m)
        recapStage = nil
    }

    // MARK: Background time (iOS) so the recap can finish if you lock the phone right after a meeting.

    private func beginBackgroundWork() -> Int {
        #if os(iOS)
        return UIApplication.shared.beginBackgroundTask(withName: "Wispen meeting recap").rawValue
        #else
        return 0
        #endif
    }

    private func endBackgroundWork(_ id: Int) {
        #if os(iOS)
        UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: id))
        #endif
    }
}

/// SpeechChunker shared between the audio thread and the main actor.
final class LockedChunker: @unchecked Sendable {
    private var chunker = SpeechChunker()
    private let lock = NSLock()

    func append(_ samples: [Float]) -> [SpeechChunker.Chunk] {
        lock.lock()
        defer { lock.unlock() }
        return chunker.append(samples)
    }

    func flush() -> SpeechChunker.Chunk? {
        lock.lock()
        defer { lock.unlock() }
        return chunker.flush()
    }
}
