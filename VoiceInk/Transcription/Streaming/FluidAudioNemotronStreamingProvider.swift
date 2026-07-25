import FluidAudio
import Foundation
import os

/// True streaming provider backed by FluidAudio's Nemotron multilingual manager.
final class FluidAudioNemotronStreamingProvider: StreamingTranscriptionProvider {
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "FluidAudioNemotronStreaming")
    private var manager: StreamingNemotronMultilingualAsrManager?
    private var eventsContinuation: AsyncStream<StreamingTranscriptionEvent>.Continuation?

    private(set) var transcriptionEvents: AsyncStream<StreamingTranscriptionEvent>

    init() {
        var continuation: AsyncStream<StreamingTranscriptionEvent>.Continuation!
        transcriptionEvents = AsyncStream { continuation = $0 }
        eventsContinuation = continuation
    }

    deinit {
        eventsContinuation?.finish()
    }

    func connect(model: any TranscriptionModel, language: String?) async throws {
        let cacheDirectory = FluidAudioModelManager.nemotronCacheDirectory(for: model.name)
        let manager = StreamingNemotronMultilingualAsrManager()
        let continuation = eventsContinuation

        await manager.setPartialCallback { partial in
            continuation?.yield(.partial(text: partial))
        }
        try await manager.loadModels(from: cacheDirectory)
        // `language` is the recording-start snapshot; it must not be re-derived
        // from the live keyboard, which the user may switch mid-dictation.
        let compatibleLanguage = KeyboardLanguagePolicy.resolvedLanguage(language, for: model)
        let languageHint = FluidAudioModelManager.nemotronLanguageHint(from: compatibleLanguage)
        // Prompt id only — see the note in FluidAudioTranscriptionService about
        // why `setForcedPrefix` must stay off.
        await manager.setLanguage(languageHint)

        self.manager = manager
        eventsContinuation?.yield(.sessionStarted)
        logger.notice("Nemotron streaming started for \(model.displayName, privacy: .public)")
    }

    func sendAudioChunk(_ data: Data) async throws {
        guard let manager else {
            throw StreamingTranscriptionError.notConnected
        }

        let samples = PCMAudioConverter.float32Samples(fromPCM16Data: data)
        guard !samples.isEmpty else { return }

        _ = try await manager.process(samples: samples)
    }

    /// One second of silence at 16 kHz, fed before the final flush.
    ///
    /// The encoder is trained with right context (`att_context_size` [42, 13]),
    /// so it will not emit the last tokens of an utterance until audio follows
    /// them — and a dictation ends the instant the hotkey is released. Without
    /// this, the final word loses its ending ("работи" arrives as "работ") and a
    /// short utterance can disappear entirely. Measured on 13 consecutive
    /// dictations: every truncated ending was restored, and one empty transcript
    /// came back as text.
    ///
    /// The batch path in `FluidAudioTranscriptionService` has always padded for
    /// this reason. Only the streaming path was missing it.
    private static let trailingSilenceSampleCount = 16_000

    func commit() async throws {
        guard let manager else {
            throw StreamingTranscriptionError.notConnected
        }

        _ = try? await manager.process(
            samples: [Float](repeating: 0, count: Self.trailingSilenceSampleCount)
        )

        let finalText = try await manager.finish()
        let text = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = TextNormalizer.shared.normalizeSentence(text)
        eventsContinuation?.yield(.committed(text: normalized))
    }

    func disconnect() async {
        await manager?.cleanup()
        manager = nil
        eventsContinuation?.finish()
        logger.notice("Nemotron streaming disconnected")
    }
}
