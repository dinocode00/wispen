import Foundation
import WhisperKit
import WispenCore

enum TranscriberError: LocalizedError {
    case notLoaded

    var errorDescription: String? { "The speech model isn't loaded yet." }
}

/// On-device speech-to-text with WhisperKit (Whisper compiled for the Apple Neural Engine).
actor WhisperTranscriber {
    private var pipe: WhisperKit?
    private(set) var loadedModelID: String?
    private var loading: Task<Void, Error>?

    var isLoaded: Bool { pipe != nil }

    /// Downloads (first time only) and loads a model. Safe to call repeatedly.
    /// - Parameter progress: download progress 0…1; only called when files actually need downloading.
    func load(modelID: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        if loadedModelID == modelID, pipe != nil { return }
        if let loading { return try await loading.value }

        let task = Task {
            self.pipe = nil
            // Reuse the copy already on disk; only talk to the network when it's missing.
            let folder: URL
            if let cached = Self.cachedFolder(for: modelID) {
                folder = cached
            } else {
                folder = try await WhisperKit.download(variant: modelID, progressCallback: { p in
                    progress(p.fractionCompleted)
                })
                UserDefaults.standard.set(folder.path, forKey: Self.folderKey(modelID))
            }
            let config = WhisperKitConfig(
                model: modelID,
                modelFolder: folder.path,
                computeOptions: Self.computeOptions,
                verbose: false,
                logLevel: .error,
                prewarm: false, // prewarm loads everything twice; a normal load is enough
                load: true,
                download: false)
            let pipe = try await WhisperKit(config)
            self.finishLoading(pipe, modelID: modelID)
        }
        loading = task
        defer { loading = nil }
        do {
            try await task.value
        } catch {
            // A damaged download: forget it so the next attempt fetches it again.
            UserDefaults.standard.removeObject(forKey: Self.folderKey(modelID))
            throw error
        }
    }

    /// Whether the model's files are already on this device.
    static func isDownloaded(_ modelID: String) -> Bool { cachedFolder(for: modelID) != nil }

    private static func folderKey(_ modelID: String) -> String { "whisperModelFolder.\(modelID)" }

    private static func cachedFolder(for modelID: String) -> URL? {
        var candidates: [URL] = []
        if let saved = UserDefaults.standard.string(forKey: folderKey(modelID)) {
            candidates.append(URL(fileURLWithPath: saved))
        }
        // WhisperKit's default download location (covers installs from before this cache existed).
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            candidates.append(docs.appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml/\(modelID)"))
        }
        let required = ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc"]
        return candidates.first { folder in
            required.allSatisfy { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
        }
    }

    private func finishLoading(_ pipe: WhisperKit, modelID: String) {
        self.pipe = pipe
        self.loadedModelID = modelID
    }

    func unload() {
        pipe = nil
        loadedModelID = nil
    }

    /// The keyboard flow runs while Wispen is in the background, where iOS forbids GPU work.
    /// The Neural Engine is allowed, and it's the fastest option anyway.
    private static var computeOptions: ModelComputeOptions {
        ModelComputeOptions(melCompute: .cpuOnly, audioEncoderCompute: .cpuAndNeuralEngine,
                            textDecoderCompute: .cpuAndNeuralEngine, prefillCompute: .cpuOnly)
    }

    /// - Parameters:
    ///   - prompt: vocabulary hint (e.g. "Glossary: Wispen, Kubernetes.") that biases recognition.
    ///   - language: ISO code, or nil to auto-detect.
    func transcribe(_ samples: [Float], prompt: String?, language: String?, englishOnlyModel: Bool) async throws -> String {
        guard let pipe else { throw TranscriberError.notLoaded }
        let options = decodingOptions(pipe: pipe, prompt: prompt, language: language, englishOnlyModel: englishOnlyModel)
        let results: [TranscriptionResult] = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
        var text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        // Whisper occasionally echoes the prompt back on near-silent audio.
        if let prompt { text = text.replacingOccurrences(of: prompt, with: "") }
        return text
    }

    /// Meeting transcription: words with their times (seconds from the start of `samples`), so each
    /// word can later be matched to whoever was speaking at that moment.
    func transcribeWords(_ samples: [Float], prompt: String?, language: String?, englishOnlyModel: Bool) async throws -> [TimedText] {
        guard let pipe else { throw TranscriberError.notLoaded }
        var options = decodingOptions(pipe: pipe, prompt: prompt, language: language, englishOnlyModel: englishOnlyModel)
        options.withoutTimestamps = false
        options.wordTimestamps = true
        let results: [TranscriptionResult] = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
        var out: [TimedText] = []
        for segment in results.flatMap(\.segments) {
            if let words = segment.words, !words.isEmpty {
                out += words.map { TimedText(text: $0.word, start: Double($0.start), end: Double($0.end)) }
            } else {
                out.append(TimedText(text: segment.text, start: Double(segment.start), end: Double(segment.end)))
            }
        }
        if let prompt, out.map(\.text).joined().contains(prompt) { return [] }
        return out
    }

    private func decodingOptions(pipe: WhisperKit, prompt: String?, language: String?, englishOnlyModel: Bool) -> DecodingOptions {
        var options = DecodingOptions()
        options.task = .transcribe
        options.language = englishOnlyModel ? "en" : language
        options.detectLanguage = !englishOnlyModel && language == nil
        options.temperature = 0
        options.skipSpecialTokens = true
        options.withoutTimestamps = true
        options.chunkingStrategy = .vad
        if let prompt, let tokenizer = pipe.tokenizer {
            options.promptTokens = tokenizer.encode(text: " " + prompt)
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            options.usePrefillPrompt = true
        }
        return options
    }
}
