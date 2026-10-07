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
    func load(modelID: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        if loadedModelID == modelID, pipe != nil { return }
        if let loading { return try await loading.value }

        let task = Task {
            self.pipe = nil
            let folder = try await WhisperKit.download(variant: modelID, progressCallback: { p in
                progress(p.fractionCompleted)
            })
            let config = WhisperKitConfig(
                model: modelID,
                modelFolder: folder.path,
                computeOptions: Self.computeOptions,
                verbose: false,
                logLevel: .error,
                prewarm: true,
                load: true,
                download: false)
            let pipe = try await WhisperKit(config)
            self.finishLoading(pipe, modelID: modelID)
        }
        loading = task
        defer { loading = nil }
        try await task.value
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
        let results: [TranscriptionResult] = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
        var text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        // Whisper occasionally echoes the prompt back on near-silent audio.
        if let prompt { text = text.replacingOccurrences(of: prompt, with: "") }
        return text
    }
}
