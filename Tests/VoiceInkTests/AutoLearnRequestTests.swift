import Foundation
import Testing

@testable import VoiceInk

/// Auto Learn reviews run in the background, unlike enhancement, which a
/// dictation waits on, so they get their own timeout and skip a hybrid model's
/// thinking phase.
@Suite(.serialized)
struct AutoLearnRequestTests {
    private let defaults = UserDefaults.standard

    private func withStoredTimeouts(
        autoLearn: Int?, enhancement: Int?, _ body: () -> Void
    ) {
        let keys = [AutoLearnSettings.requestTimeoutKey, EnhancementRequestSettings.timeoutKey]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        for (key, value) in zip(keys, [autoLearn, enhancement]) {
            if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        body()
    }

    @Test func reviewTimeoutDefaultsToCoveringASharedServersPriorityWait() {
        withStoredTimeouts(autoLearn: nil, enhancement: 7) {
            #expect(AutoLearnSettings.requestTimeout == 330)
        }
    }

    @Test func reviewTimeoutIsIndependentOfTheEnhancementTimeout() {
        withStoredTimeouts(autoLearn: 90, enhancement: 15) {
            #expect(AutoLearnSettings.requestTimeout == 90)
            #expect(EnhancementRequestSettings.timeout == 15)
        }
    }

    @Test func thinkingIsSwitchedOffThroughTheChatTemplate() throws {
        let body = CustomProviderRequestOptions.thinkingDisabledExtraBody
        let kwargs = try #require(body["chat_template_kwargs"] as? [String: Bool])
        #expect(kwargs == ["enable_thinking": false])
    }
}
