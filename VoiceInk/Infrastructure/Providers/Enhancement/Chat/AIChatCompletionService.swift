import Foundation
import LLMkit

enum CustomProviderRequestOptions {
    /// Asks an OpenAI-compatible server to skip a hybrid model's thinking
    /// phase. `chat_template_kwargs` is how vLLM, SGLang and
    /// mlx-openai-server pass options to the chat template, and Qwen3's
    /// template reads `enable_thinking`; mlx-openai-server defaults it to
    /// true. A strict server may reject the unknown field, so only
    /// `RemoteRefineRequest` sends it.
    static var thinkingDisabledExtraBody: [String: Any] {
        ["chat_template_kwargs": ["enable_thinking": false]]
    }
}

/// VoiceInk Refine served by an OpenAI-compatible server, as `voiceink-refine`
/// on m3 (scrapeui X-4660), asked the way the local Refine engine asks it: the
/// raw transcript under its trained instruction, thinking off. Measured on m3
/// 2026-10-17: like that it cleaned a dictation in 0.8 s; with thinking on (the
/// server's default) it wrote a "Thinking Process" for 2,048 tokens and never
/// answered. A mode's general prompt and the `<TRANSCRIPT>` wrapper are not
/// what it was trained on.
enum RemoteRefineRequest {
    static let servedModelName = "voiceink-refine"

    static func applies(provider: AIProvider, modelName: String?) -> Bool {
        provider == .custom
            && modelName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == servedModelName
    }

    static func messages(for transcript: String) -> [ChatMessage] {
        [.user(transcript)]
    }

    static var systemPrompt: String {
        VoiceInkRefineService.systemPrompt
    }
}

struct AIChatCompletionResult: Sendable {
    let text: String
    let openRouterCompletion: OpenRouterCompletion?
}

extension AIService {
    func performChatCompletion(
        provider: AIProvider,
        modelName: String?,
        messages: [ChatMessage],
        systemPrompt: String? = nil,
        localUserPrompt: String? = nil,
        timeout: TimeInterval = 30,
        retryOnTimeout: Bool = false,
        disablesThinking: Bool = false
    ) async throws -> AIChatCompletionResult {
        let resolvedModel = modelName?.isEmpty == false ? modelName! : selectedModel(for: provider)

        let result: String
        var openRouterCompletion: OpenRouterCompletion? = nil
        switch provider {
        case .gemini:
            result = try await GeminiLLMClient.chatCompletion(
                apiKey: try chatAPIKey(for: provider, modelName: resolvedModel),
                model: resolvedModel,
                messages: messages,
                systemPrompt: systemPrompt,
                thinkingLevel: ReasoningConfig.geminiThinkingLevel(for: resolvedModel),
                store: false,
                timeout: timeout,
                retryOnTimeout: retryOnTimeout
            )
        case .anthropic:
            result = try await AnthropicLLMClient.chatCompletion(
                apiKey: try chatAPIKey(for: provider, modelName: resolvedModel),
                model: resolvedModel,
                messages: messages,
                systemPrompt: systemPrompt,
                timeout: timeout,
                retryOnTimeout: retryOnTimeout
            )
        case .openRouter:
            let policy = OpenRouterRequestPolicy.lowLatency(
                modelName: resolvedModel,
                modelMetadata: openRouterModelMetadata(for: resolvedModel)
            )
            let completion = try await OpenRouterClient.chatCompletion(
                apiKey: try chatAPIKey(for: provider, modelName: resolvedModel),
                model: policy.model,
                messages: messages,
                systemPrompt: systemPrompt,
                temperature: policy.temperature,
                reasoning: policy.reasoning,
                provider: policy.provider,
                includeRouterMetadata: true,
                appReferer: URL(string: "https://tryvoiceink.com"),
                appTitle: "VoiceInk",
                timeout: timeout,
                retryOnTimeout: retryOnTimeout
            )
            guard !OpenRouterRequestPolicy.outputWasTruncated(finishReason: completion.finishReason) else {
                throw EnhancementError.outputTruncated
            }
            result = completion.text
            openRouterCompletion = completion
        case .custom:
            guard
                let customConfiguration = CustomAIProviderManager.shared.requestConfiguration(forModel: resolvedModel),
                let baseURL = URL(string: customConfiguration.baseURL)
            else {
                throw EnhancementError.notConfigured
            }
            result = try await OpenAILLMClient.chatCompletion(
                baseURL: baseURL,
                apiKey: customConfiguration.apiKey,
                model: customConfiguration.modelName,
                messages: messages,
                systemPrompt: systemPrompt,
                temperature: 0.3,
                extraBody: disablesThinking ? CustomProviderRequestOptions.thinkingDisabledExtraBody : nil,
                timeout: timeout,
                retryOnTimeout: retryOnTimeout
            )
        case .voiceInkRefine:
            throw EnhancementError.customError(
                String(localized: "VoiceInk Refine only supports transcript cleanup.")
            )
        case .ollama:
            result = try await enhanceWithOllama(
                text: localUserPrompt ?? chatPrompt(from: messages),
                systemPrompt: systemPrompt ?? "",
                model: resolvedModel,
                timeout: timeout,
                retryOnTimeout: retryOnTimeout
            )
        case .localCLI:
            result = try await enhanceWithLocalCLI(
                systemPrompt: systemPrompt ?? "",
                userPrompt: localUserPrompt ?? chatPrompt(from: messages)
            )
        default:
            guard let baseURL = URL(string: provider.baseURL) else {
                throw EnhancementError.notConfigured
            }
            let reasoningEffort = ReasoningConfig.getReasoningParameter(
                for: provider,
                modelName: resolvedModel
            )
            let extraBody = ReasoningConfig.getExtraBodyParameters(
                for: provider,
                modelName: resolvedModel
            )
            result = try await OpenAILLMClient.chatCompletion(
                baseURL: baseURL,
                apiKey: try chatAPIKey(for: provider, modelName: resolvedModel),
                model: resolvedModel,
                messages: messages,
                systemPrompt: systemPrompt,
                temperature: 0.3,
                reasoningEffort: reasoningEffort,
                extraBody: extraBody,
                timeout: timeout,
                retryOnTimeout: retryOnTimeout
            )
        }

        return AIChatCompletionResult(text: result, openRouterCompletion: openRouterCompletion)
    }

    func completeChat(
        provider: AIProvider,
        modelName: String?,
        messages: [ChatMessage],
        systemPrompt: String? = nil,
        timeout: TimeInterval = 30,
        retryOnTimeout: Bool = false
    ) async throws -> String {
        let completion = try await performChatCompletion(
            provider: provider,
            modelName: modelName,
            messages: messages,
            systemPrompt: systemPrompt,
            timeout: timeout,
            retryOnTimeout: retryOnTimeout
        )
        let result = completion.text
        let filteredResult = AIEnhancementOutputFilter.filter(result)
        guard provider != .openRouter || !filteredResult.isEmpty else {
            throw EnhancementError.enhancementFailed
        }
        return filteredResult
    }

    private func chatAPIKey(for provider: AIProvider, modelName: String) throws -> String {
        if provider == .custom {
            guard let customConfiguration = CustomAIProviderManager.shared.requestConfiguration(forModel: modelName)
            else {
                throw EnhancementError.notConfigured
            }
            return customConfiguration.apiKey
        }

        guard let key = APIKeyManager.shared.getAPIKey(forProvider: provider.rawValue), !key.isEmpty else {
            throw EnhancementError.notConfigured
        }
        return key
    }

    private func chatPrompt(from messages: [ChatMessage]) -> String {
        let formattedMessages = messages.map { message in
            let label: String
            switch message.role {
            case "assistant":
                label = "assistant"
            case "user":
                label = "user"
            case "system":
                label = "system"
            default:
                label = "other"
            }
            return """
                <message role="\(label)">
                \(message.content)
                </message>
                """
        }
        .joined(separator: "\n\n")

        return """
            <conversation>
            \(formattedMessages)
            </conversation>
            """
    }
}
