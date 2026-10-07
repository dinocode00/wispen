import Foundation
import WispenCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Builds the language model chosen in Settings, or nil for rule-based cleanup only.
enum GeneratorFactory {
    static func make(for settings: WispenSettings) -> TextGenerator? {
        switch settings.llmProvider {
        case .appleIntelligence:
            #if canImport(FoundationModels)
            if #available(iOS 26.0, macOS 26.0, *) { return AppleIntelligenceGenerator() }
            #endif
            return nil
        case .ollama:
            guard let url = URL(string: settings.ollamaURL) else { return nil }
            return OllamaGenerator(baseURL: url, model: settings.ollamaModel, contextTokens: settings.ollamaContextTokens)
        case .rulesOnly:
            return nil
        }
    }

    /// Human-readable status for the Settings/Home screens.
    static func appleIntelligenceStatus() -> (ready: Bool, message: String) {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            return AppleIntelligenceGenerator.status()
        }
        #endif
        return (false, "Needs iOS 26 / macOS 26 with Apple Intelligence. Using rule-based cleanup.")
    }
}

#if canImport(FoundationModels)
/// Apple's ~3B-parameter on-device model (Apple Intelligence). Free, private, offline.
@available(iOS 26.0, macOS 26.0, *)
struct AppleIntelligenceGenerator: TextGenerator {
    var contextTokens: Int { 4096 }

    var isAvailable: Bool {
        get async { SystemLanguageModel.default.isAvailable }
    }

    func generate(instructions: String, prompt: String, temperature: Double?) async throws -> String {
        let session = LanguageModelSession(instructions: instructions)
        do {
            let response = try await session.respond(to: prompt, options: GenerationOptions(temperature: temperature))
            return response.content
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize: throw LLMError.contextOverflow
            case .guardrailViolation: throw LLMError.refused
            default: throw LLMError.failed(error.localizedDescription)
            }
        }
    }

    static func status() -> (ready: Bool, message: String) {
        switch SystemLanguageModel.default.availability {
        case .available:
            return (true, "Apple Intelligence is ready.")
        case .unavailable(.deviceNotEligible):
            return (false, "This device doesn't support Apple Intelligence. Using rule-based cleanup.")
        case .unavailable(.appleIntelligenceNotEnabled):
            return (false, "Turn on Apple Intelligence in Settings › Apple Intelligence & Siri.")
        case .unavailable(.modelNotReady):
            return (false, "Apple Intelligence is still downloading its model. Try again later.")
        case .unavailable:
            return (false, "Apple Intelligence is unavailable right now.")
        }
    }
}
#endif
