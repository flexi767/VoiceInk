import Foundation
import Testing

@testable import VoiceInk

/// The "Punctuation only" template exists for small local models that over-edit under the
/// system instructions, so it must reach the model without them and keep its word-preserving rule.
struct PromptTemplatesTests {
    @Test func templateIdsAreUnique() {
        let ids = PromptTemplates.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func punctuationOnlyRunsWithoutTheSystemInstructions() throws {
        let template = try #require(PromptTemplates.all.first { $0.id == PromptTemplates.punctuationOnlyPromptId })
        let prompt = template.toCustomPrompt(id: template.id)
        #expect(template.title == "Punctuation only")
        #expect(!prompt.useSystemInstructions)
        // Without the system template the prompt text is sent as is: no self-correction rule.
        #expect(prompt.finalPromptText == template.promptText)
        #expect(prompt.finalPromptText.contains("<TRANSCRIPT>"))
        #expect(prompt.finalPromptText.contains("Never add, remove, replace, reorder or translate words"))
    }
}
