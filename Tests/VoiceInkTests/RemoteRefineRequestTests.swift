import Foundation
import LLMkit
import Testing

@testable import VoiceInk

/// VoiceInk Refine served by an OpenAI-compatible server (scrapeui X-4660 on
/// m3) must be asked the way the local Refine engine asks it: raw transcript,
/// its trained instruction, thinking off. A mode's general prompt and the
/// `<TRANSCRIPT>` wrapper are not what it was trained on.
struct RemoteRefineRequestTests {
    @Test func appliesToTheServedRefineModelOnACustomProvider() {
        #expect(RemoteRefineRequest.applies(provider: .custom, modelName: "voiceink-refine"))
        #expect(RemoteRefineRequest.applies(provider: .custom, modelName: " VoiceInk-Refine "))
    }

    @Test func leavesOtherModelsAndProvidersOnTheGeneralPath() {
        #expect(!RemoteRefineRequest.applies(provider: .custom, modelName: "qwen3-4b"))
        #expect(!RemoteRefineRequest.applies(provider: .custom, modelName: nil))
        #expect(!RemoteRefineRequest.applies(provider: .openAI, modelName: "voiceink-refine"))
        #expect(!RemoteRefineRequest.applies(provider: .voiceInkRefine, modelName: "voiceink-refine"))
    }

    @Test func sendsTheRawTranscriptUnderRefinesOwnInstruction() {
        let transcript = "hi maya comma quick update period"
        let messages = RemoteRefineRequest.messages(for: transcript)
        #expect(messages.map(\.role) == ["user"])
        #expect(messages.map(\.content) == [transcript])
        #expect(RemoteRefineRequest.systemPrompt == VoiceInkRefineService.systemPrompt)
    }

    @Test func switchesThinkingOffThroughTheChatTemplate() throws {
        let body = CustomProviderRequestOptions.thinkingDisabledExtraBody
        let kwargs = try #require(body["chat_template_kwargs"] as? [String: Bool])
        #expect(kwargs == ["enable_thinking": false])
    }
}
