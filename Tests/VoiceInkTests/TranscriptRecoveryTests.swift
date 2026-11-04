import Foundation
import Testing

@testable import VoiceInk

/// Drives the pipeline's retries through a scripted transcriber: which engine
/// requests they make, how many, and which transcript survives. The detectors'
/// own thresholds are covered by their tests; these cover the wiring.
@MainActor
struct TranscriptRecoveryTests {

    /// Answers each request with the next scripted result and records it.
    final class ScriptedTranscriber {
        struct Request {
            let model: String
            let language: String?
            let prompt: String?
        }

        var results: [Result<String, Error>]
        private(set) var requests: [Request] = []
        var onRequest: () -> Void = {}

        init(_ results: [Result<String, Error>]) {
            self.results = results
        }

        func transcribe(_ url: URL, _ model: any TranscriptionModel, _ context: TranscriptionRequestContext)
            async throws -> String
        {
            requests.append(Request(model: model.name, language: context.language, prompt: context.prompt))
            onRequest()
            guard !results.isEmpty else { throw TestError.unscripted }
            return try results.removeFirst().get()
        }
    }

    enum TestError: Error { case unscripted, engineFailed }

    private static func model(_ name: String) -> NativeAppleModel {
        NativeAppleModel(
            name: name, displayName: name, description: "", isMultilingualModel: true, supportedLanguages: [:])
    }

    private static let nemotron = model("nemotron-multilingual-0.6b")
    private static let whisper = model("ggml-large-v3-turbo")
    private static let audio = URL(fileURLWithPath: "/dev/null")

    private static let cutOff = "Ich."
    private static let complete = "Ich spreche gerade auf Deutsch und es funktioniert."
    private static let looping = "Thank you very much. Thank you very much. Thank you very much. Thank you very much."
    private static let bulgarian = "Диктувам на български и искам да видя дали работи."

    private func configuration(
        language: String, fallback: TranscriptionFallback? = nil
    ) -> TranscriptionRuntimeConfiguration {
        TranscriptionRuntimeConfiguration(
            mode: ModeConfig(name: "Test", isAIEnhancementEnabled: false),
            model: Self.nemotron,
            language: language,
            languageCandidates: [language],
            isRealtimeEnabled: true,
            fallback: fallback
        )
    }

    private func recovery(_ transcriber: ScriptedTranscriber, duration: TimeInterval = 5) -> TranscriptRecovery {
        TranscriptRecovery(
            transcribe: transcriber.transcribe,
            audioDuration: { _ in duration },
            isMisspelled: { _, _ in false }
        )
    }

    private func run(
        _ text: String,
        _ transcriber: ScriptedTranscriber,
        streamed: Bool = true,
        configuration: TranscriptionRuntimeConfiguration,
        context: TranscriptionRequestContext? = nil,
        shouldCancel: () -> Bool = { false }
    ) async -> (text: String, model: any TranscriptionModel) {
        await recovery(transcriber).recover(
            text,
            audioURL: Self.audio,
            streamed: streamed,
            context: context ?? configuration.requestContext,
            configuration: configuration,
            shouldCancel: shouldCancel
        )
    }

    // MARK: - Cut-off stream

    @Test func reDecodesACutOffStreamOnceWithTheSameModelAndRequest() async {
        let transcriber = ScriptedTranscriber([.success(Self.complete)])
        let context = TranscriptionRequestContext(language: "de", prompt: "Hallo.")
        let result = await run(Self.cutOff, transcriber, configuration: configuration(language: "de"), context: context)

        #expect(result.text == Self.complete)
        #expect(result.model.name == Self.nemotron.name)
        #expect(transcriber.requests.count == 1)
        #expect(transcriber.requests.first?.model == Self.nemotron.name)
        #expect(transcriber.requests.first?.language == "de")
        #expect(transcriber.requests.first?.prompt == "Hallo.")
    }

    @Test func keepsTheStreamWhenTheReDecodeIsNoLongerAndDoesNotRetryAgain() async {
        // The retry is still cut off; one re-decode is all a recording gets.
        let transcriber = ScriptedTranscriber([.success("Ich"), .success(Self.complete)])
        let result = await run(Self.cutOff, transcriber, configuration: configuration(language: "de"))

        #expect(result.text == Self.cutOff)
        #expect(transcriber.requests.count == 1)
    }

    @Test func keepsTheStreamWhenTheReDecodeFails() async {
        let transcriber = ScriptedTranscriber([.failure(TestError.engineFailed)])
        let result = await run(Self.cutOff, transcriber, configuration: configuration(language: "de"))

        #expect(result.text == Self.cutOff)
        #expect(transcriber.requests.count == 1)
    }

    @Test func leavesABatchTranscriptAlone() async {
        let transcriber = ScriptedTranscriber([.success(Self.complete)])
        let result = await run(Self.cutOff, transcriber, streamed: false, configuration: configuration(language: "de"))

        #expect(result.text == Self.cutOff)
        #expect(transcriber.requests.isEmpty)
    }

    // MARK: - Nonsense fallback

    @Test func reRunsNonsenseOnceOnTheFallbackModelInItsLanguage() async {
        let transcriber = ScriptedTranscriber([.success(Self.bulgarian)])
        let config = configuration(
            language: "bg", fallback: TranscriptionFallback(model: Self.whisper, language: "bg"))
        let result = await run(Self.looping, transcriber, streamed: false, configuration: config)

        #expect(result.text == Self.bulgarian)
        #expect(result.model.name == Self.whisper.name)
        #expect(transcriber.requests.count == 1)
        #expect(transcriber.requests.first?.model == Self.whisper.name)
        #expect(transcriber.requests.first?.language == "bg")
    }

    @Test func keepsThePrimaryWhenTheFallbackIsAlsoNonsenseAndDoesNotRetryAgain() async {
        let transcriber = ScriptedTranscriber([.success(Self.looping), .success(Self.bulgarian)])
        let config = configuration(
            language: "bg", fallback: TranscriptionFallback(model: Self.whisper, language: "bg"))
        let result = await run(Self.looping, transcriber, streamed: false, configuration: config)

        #expect(result.text == Self.looping)
        #expect(result.model.name == Self.nemotron.name)
        #expect(transcriber.requests.count == 1)
    }

    @Test func keepsThePrimaryWhenTheFallbackFails() async {
        let transcriber = ScriptedTranscriber([.failure(TestError.engineFailed)])
        let config = configuration(
            language: "bg", fallback: TranscriptionFallback(model: Self.whisper, language: "bg"))
        let result = await run(Self.looping, transcriber, streamed: false, configuration: config)

        #expect(result.text == Self.looping)
        #expect(result.model.name == Self.nemotron.name)
    }

    @Test func doesNotReRunNonsenseWithoutAFallbackModel() async {
        let transcriber = ScriptedTranscriber([.success(Self.bulgarian)])
        let result = await run(Self.looping, transcriber, streamed: false, configuration: configuration(language: "bg"))

        #expect(result.text == Self.looping)
        #expect(transcriber.requests.isEmpty)
    }

    // MARK: - Both retries, cancellation

    @Test func aCutOffStreamThatReDecodesToNonsenseGetsOneOfEachRetry() async {
        let transcriber = ScriptedTranscriber([.success(Self.looping), .success(Self.bulgarian), .success("x")])
        let config = configuration(
            language: "bg", fallback: TranscriptionFallback(model: Self.whisper, language: "bg"))
        let result = await run("Да.", transcriber, configuration: config)

        #expect(result.text == Self.bulgarian)
        #expect(result.model.name == Self.whisper.name)
        #expect(transcriber.requests.map(\.model) == [Self.nemotron.name, Self.whisper.name])
    }

    @Test func makesNoRequestOnceTheUserHasCancelled() async {
        let transcriber = ScriptedTranscriber([.success(Self.complete), .success(Self.bulgarian)])
        let config = configuration(
            language: "bg", fallback: TranscriptionFallback(model: Self.whisper, language: "bg"))
        let result = await run(Self.looping, transcriber, configuration: config, shouldCancel: { true })

        #expect(result.text == Self.looping)
        #expect(transcriber.requests.isEmpty)
    }

    @Test func aCancelDuringTheReDecodeStopsTheFallback() async {
        var cancelled = false
        let transcriber = ScriptedTranscriber([.success(Self.looping), .success(Self.bulgarian)])
        transcriber.onRequest = { cancelled = true }
        let config = configuration(
            language: "bg", fallback: TranscriptionFallback(model: Self.whisper, language: "bg"))
        _ = await run("Да.", transcriber, configuration: config, shouldCancel: { cancelled })

        #expect(transcriber.requests.count == 1)
    }

    @Test func aCancelledReDecodeKeepsTheStream() async {
        let transcriber = ScriptedTranscriber([.failure(CancellationError())])
        let result = await run(Self.cutOff, transcriber, configuration: configuration(language: "de"))

        #expect(result.text == Self.cutOff)
        #expect(transcriber.requests.count == 1)
    }
}
