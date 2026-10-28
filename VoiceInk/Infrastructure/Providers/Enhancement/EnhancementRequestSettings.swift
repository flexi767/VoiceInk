import Foundation

enum EnhancementRequestSettings {
    static let timeoutKey = "EnhancementTimeoutSeconds"
    static let retryOnTimeoutKey = "EnhancementRetryOnTimeout"
    static let defaultTimeoutSeconds = 7
    static let defaultRetryOnTimeout = true
    static let maximumAttempts = 3

    static var timeout: TimeInterval {
        let configuredTimeout = UserDefaults.standard.integer(forKey: timeoutKey)
        return TimeInterval(configuredTimeout > 0 ? configuredTimeout : defaultTimeoutSeconds)
    }

    static var retryOnTimeout: Bool {
        guard UserDefaults.standard.object(forKey: retryOnTimeoutKey) != nil else {
            return defaultRetryOnTimeout
        }
        return UserDefaults.standard.bool(forKey: retryOnTimeoutKey)
    }

    /// Providers whose chat request goes through LLMkit's `performRequest` with its default retries
    /// (connection failures, 429 and 5xx, after 1 s and 2 s): `OpenAILLMClient`, `GeminiLLMClient`
    /// and `AnthropicLLMClient`. Retrying those failures again in `EnhancementRetryLoop` turned one
    /// unavailable server into nine requests. OpenRouter's client opts out of LLMkit retries
    /// (`maxRetries: 0`), so it keeps the loop's; Ollama, Local CLI and VoiceInk Refine map their
    /// errors before the loop sees them.
    static let providersRetriedByLLMkit: Set<AIProvider> = [
        .custom, .openAI, .groq, .cerebras, .mistral, .gemini, .anthropic,
    ]
}
