import Foundation
import WispenCore
#if canImport(FoundationModels)
import FoundationModels
#endif
#if os(iOS)
import UIKit
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
        try await generate(instructions: instructions, prompt: prompt, temperature: temperature, maxTokens: 2000)
    }

    func generate(instructions: String, prompt: String, temperature: Double?, maxTokens: Int) async throws -> String {
        // Apple Intelligence limits how often an app may use the model, much more so in the background.
        // While Wispen is open, wait and try again; in the background, report it so the work can resume
        // when Wispen is opened.
        let waits: [UInt64] = [3, 8, 15, 30]
        for attempt in 0...waits.count {
            do {
                return try await respond(instructions: instructions, prompt: prompt, temperature: temperature,
                                         maxTokens: maxTokens)
            } catch LLMError.rateLimited where attempt < waits.count {
                guard await Self.appIsActive else { throw LLMError.rateLimited }
                try await Task.sleep(nanoseconds: waits[attempt] * 1_000_000_000)
            }
        }
        throw LLMError.rateLimited
    }

    private func respond(instructions: String, prompt: String, temperature: Double?, maxTokens: Int) async throws -> String {
        let session = LanguageModelSession(instructions: instructions)
        let limit = responseLimit(instructions: instructions, prompt: prompt, wanted: maxTokens)
        do {
            let response = try await session.respond(
                to: prompt, options: GenerationOptions(temperature: temperature, maximumResponseTokens: limit))
            return response.content
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize: throw LLMError.contextOverflow
            case .guardrailViolation: throw LLMError.refused
            case .rateLimited: throw LLMError.rateLimited
            default:
                // Too many requests at once is the same kind of "slow down".
                if "\(error)".localizedCaseInsensitiveContains("concurrent") { throw LLMError.rateLimited }
                throw LLMError.failed(error.localizedDescription)
            }
        }
    }

    @MainActor static var appIsActive: Bool {
        #if os(iOS)
        UIApplication.shared.applicationState == .active
        #else
        true
        #endif
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
