import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Talks to a local Ollama server (https://ollama.com). Free, private, and with a bigger context window
/// than the on-device Apple model — handy on a Mac for long meeting recaps.
public struct OllamaGenerator: TextGenerator {
    public var baseURL: URL
    public var model: String
    public var contextTokens: Int

    public init(baseURL: URL, model: String, contextTokens: Int = 8192) {
        self.baseURL = baseURL
        self.model = model
        self.contextTokens = contextTokens
    }

    public var isAvailable: Bool {
        get async {
            var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
            request.timeoutInterval = 2
            guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
            return (response as? HTTPURLResponse)?.statusCode == 200
        }
    }

    struct ChatRequest: Encodable {
        struct Message: Encodable { let role: String; let content: String }
        struct Options: Encodable { let temperature: Double?; let num_ctx: Int }
        let model: String
        let messages: [Message]
        let stream: Bool
        let options: Options
    }

    struct ChatResponse: Decodable {
        struct Message: Decodable { let content: String }
        let message: Message?
        let error: String?
    }

    public func generate(instructions: String, prompt: String, temperature: Double?) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ChatRequest(
            model: model,
            messages: [.init(role: "system", content: instructions), .init(role: "user", content: prompt)],
            stream: false,
            options: .init(temperature: temperature, num_ctx: contextTokens)))
        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: request)
        } catch {
            throw LLMError.unavailable("Can't reach Ollama at \(baseURL.absoluteString)")
        }
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        if let error = decoded.error { throw LLMError.failed(error) }
        return decoded.message?.content ?? ""
    }
}
