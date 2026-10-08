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
    /// The meeting that just finished recording (the UI opens "Who's who?" for it if needed).
    @Published var lastFinishedMeetingID: String?

    private let app: AppModel
    private var sources: [MeetingAudioSource] = []
    private var chunkers: [ObjectIdentifier: LockedChunker] = [:]
    private var jobs: AsyncStream<Job>.Continuation?
    private var worker: Task<Void, Never>?
    private var clock: Timer?
    private var startedAt = Date()
    private var lastSave = Date()
    private var summarizing: Set<String> = []
    /// Speaker identification: temporary audio + timed words per source ("mic" or "Others").
    private var spools: [String: AudioSpool] = [:]
    private var timedWords: [String: [TimedText]] = [:]

    struct Job: Sendable {
        let label: String?
        let chunk: SpeechChunker.Chunk
    }

    init(app: AppModel) {
        self.app = app
    }

    /// - Parameter extraSources: e.g. system audio on macOS.
    /// - Parameter expectedSpeakers: how many people are in the meeting, if you know (better speaker detection).
    func start(title: String = "", micLabel: String? = nil, extraSources: [MeetingAudioSource] = [],
               expectedSpeakers: Int? = nil) async {
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

        var m = Meeting(title: title, startedAt: Date(), status: .recording)
        m.expectedSpeakers = expectedSpeakers
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
            // "Me" is already one person; everything else may be several people talking.
            let spool: AudioSpool? = app.settings.meetingSpeakerLabels && label != "Me" ? AudioSpool() : nil
            if let spool { spools[Self.key(label)] = spool }
            source.onSamples = { [weak self] samples in
                spool?.append(samples)
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

    private static func key(_ label: String?) -> String { label ?? "mic" }

    private func cancelStart() async {
        discardSpeakerData()
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
            var text: String
            let key = Self.key(job.label)
            if spools[key] != nil {
                // Keep word timings so each word can be matched to a speaker after the meeting.
                let words = try await app.transcribeWords(job.chunk.samples).compactMap { w -> TimedText? in
                    let t = WhisperArtifactFilter.clean(w.text)
                    return t.isEmpty ? nil : TimedText(text: t, start: w.start + job.chunk.start, end: w.end + job.chunk.start)
                }
                timedWords[key, default: []] += words
                text = TextTidy.tidy(words.map(\.text).joined(separator: " "))
            } else {
                text = WhisperArtifactFilter.clean(try await app.transcribe(job.chunk.samples))
            }
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
            source.onSamples = nil
            source.onLevel = nil
            if let rest = chunkers[ObjectIdentifier(source)]?.flush() {
                enqueue(Job(label: source.label, chunk: rest))
            }
        }
        chunkers.removeAll()
        // On iPhone, keep the (now muted) audio session running until the recap is written: it's what
        // lets Wispen keep working if you lock the phone right after the meeting.
        let heldSources = sources
        sources.removeAll()
        #if os(iOS)
        defer { heldSources.forEach { $0.stop() } }
        #else
        heldSources.forEach { $0.stop() }
        #endif

        let background = beginBackgroundWork()
        defer { endBackgroundWork(background) }

        recapStage = "Finishing transcript…"
        jobs?.finish()
        await worker?.value
        worker = nil
        jobs = nil

        m = meeting ?? m
        let (segments, needsReview) = await identifySpeakers(meetingID: m.id, in: m.segments, expected: m.expectedSpeakers)
        m.segments = segments
        m.duration = Date().timeIntervalSince(m.startedAt)
        if needsReview {
            // Ask "who's who?" first, so the recap uses real names.
            m.status = .needsSpeakerReview
            app.save(m)
            recapStage = nil
        } else {
            m.status = .needsRecap
            meeting = m
            app.save(m)
            await summarize(meetingID: m.id)
        }
        lastFinishedMeetingID = m.id
        meeting = nil
    }

    /// Splits each multi-person source into "Speaker 1", "Speaker 2"… using the spooled audio. When
    /// several voices are found, the audio is kept (until you've named them) so you can listen to
    /// each voice and re-detect. If anything fails, the unlabelled transcript is kept.
    private func identifySpeakers(meetingID: String, in segments: [TranscriptSegment],
                                  expected: Int?) async -> ([TranscriptSegment], Bool) {
        defer { discardSpeakerData() }
        var result = segments
        var needsReview = false
        for (key, spool) in spools {
            let words = timedWords[key] ?? []
            guard !words.isEmpty else { continue }
            recapStage = "Identifying speakers…"
            recapProgress = 0
            let samples = spool.readAll()
            guard samples.count > Int(AudioMath.sampleRate * 5) else { continue }
            do {
                let labelled = try await labelSpeakers(samples: samples, words: words, expected: expected)
                guard !labelled.isEmpty else { continue }
                result = (result.filter { $0.speaker == "Me" } + labelled).sorted { $0.start < $1.start }
                if Set(labelled.compactMap(\.speaker)).count >= 2 {
                    SpeakerReviewStore.keep(meetingID: meetingID, key: key, spool: spool, words: words)
                    needsReview = true
                }
            } catch {
                errorMessage = "Couldn't tell speakers apart: \(error.localizedDescription)"
            }
        }
        await app.diarizer.unload()
        return (result, needsReview)
    }

    private func labelSpeakers(samples: [Float], words: [TimedText], expected: Int?) async throws -> [TranscriptSegment] {
        let turns = try await app.diarizer.diarize(samples, speakers: expected) { fraction in
            Task { @MainActor [weak self] in self?.recapProgress = fraction }
        }
        guard !turns.isEmpty else { return [] }
        return SpeakerAssigner.label(words, turns: turns).map { seg in
            var seg = seg
            seg.text = DictionaryApplier.apply(seg.text, entries: app.dictionary)
            return seg
        }
    }

    // MARK: Speaker review ("Who's who?")

    /// Runs speaker detection again, e.g. with the number of people you know were there.
    func redetectSpeakers(meetingID: String, count: Int?) async {
        guard var m = app.meetings.first(where: { $0.id == meetingID }) else { return }
        defer { recapStage = nil }
        for key in SpeakerReviewStore.keys(meetingID) {
            recapStage = "Identifying speakers…"
            recapProgress = 0
            let samples = SpeakerReviewStore.samples(meetingID, key: key)
            let words = SpeakerReviewStore.words(meetingID, key: key)
            do {
                let labelled = try await labelSpeakers(samples: samples, words: words, expected: count)
                guard !labelled.isEmpty else { continue }
                m.segments = (m.segments.filter { $0.speaker == "Me" } + labelled).sorted { $0.start < $1.start }
            } catch {
                errorMessage = "Couldn't re-detect speakers: \(error.localizedDescription)"
            }
        }
        await app.diarizer.unload()
        m.expectedSpeakers = count
        app.save(m)
    }

    /// Applies the names you chose (same name = same person), deletes the kept audio, writes the recap.
    func finishSpeakerReview(meetingID: String, names: [String: String]) async {
        guard var m = app.meetings.first(where: { $0.id == meetingID }) else { return }
        m.segments = SpeakerReview.apply(names: names, to: m.segments)
        m.status = .needsRecap
        app.save(m)
        SpeakerReviewStore.delete(meetingID)
        await summarize(meetingID: meetingID)
    }

    /// Moves one transcript line to another speaker.
    func reassignSegment(_ segmentID: String, to speaker: String, in meetingID: String) {
        guard var m = app.meetings.first(where: { $0.id == meetingID }) else { return }
        m.segments = SpeakerReview.reassign(segmentID: segmentID, to: speaker, in: m.segments)
        if m.recap != nil { m.recapOutdated = true }
        app.save(m)
    }

    private func discardSpeakerData() {
        spools.values.forEach { $0.delete() }
        spools.removeAll()
        timedWords.removeAll()
    }

    /// Renames a speaker everywhere in a meeting ("Speaker 1" → "Sam"), including the recap.
    func renameSpeaker(_ old: String, to new: String, in meetingID: String) {
        let name = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != old, var m = app.meetings.first(where: { $0.id == meetingID }) else { return }
        for i in m.segments.indices where m.segments[i].speaker == old { m.segments[i].speaker = name }
        if var recap = m.recap {
            func swap(_ s: String) -> String { s.replacingOccurrences(of: old, with: name) }
            recap.summary = swap(recap.summary)
            recap.topics = recap.topics.map { RecapTopic(id: $0.id, title: swap($0.title), summary: swap($0.summary)) }
            recap.keyPoints = recap.keyPoints.map(swap)
            recap.decisions = recap.decisions.map(swap)
            recap.openQuestions = recap.openQuestions.map(swap)
            recap.risks = recap.risks.map(swap)
            recap.followUps = recap.followUps.map(swap)
            recap.actionItems = recap.actionItems.map { a in
                var a = a
                a.task = swap(a.task)
                if a.owner == old { a.owner = name } else { a.owner = a.owner.map(swap) }
                return a
            }
            m.recap = recap
        }
        app.save(m)
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
            m.recapOutdated = nil
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
