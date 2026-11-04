import Foundation
import os

/// The retries a finished transcript gets before cleanup: a batch re-decode of
/// a cut-off stream, wrong-language retries, and the fallback model for a
/// nonsense transcript. Each runs at most once, in that order.
///
/// Split out of `TranscriptionPipeline` so the retries can be tested with a
/// scripted transcriber: they reach the engines only through `transcribe`,
/// and read the recording's length only through `audioDuration`.
@MainActor
struct TranscriptRecovery {
    typealias Transcribe = @MainActor (URL, any TranscriptionModel, TranscriptionRequestContext) async throws -> String

    let transcribe: Transcribe
    var audioDuration: (URL) async -> TimeInterval = { await AudioFileMetadata.duration(for: $0) }
    var isMisspelled: TranscriptNonsenseDetector.MisspellingCheck = TranscriptNonsenseDetector.systemIsMisspelled

    private static let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "TranscriptionPipeline")

    /// Runs the retries on `text`, the filtered primary transcript, and returns
    /// the transcript to keep with the model that produced it.
    ///
    /// A failed or cancelled retry keeps the transcript it would have replaced;
    /// the caller checks `shouldCancel` afterwards and discards the result.
    func recover(
        _ text: String,
        audioURL: URL,
        streamed: Bool,
        context: TranscriptionRequestContext,
        configuration: TranscriptionRuntimeConfiguration,
        shouldCancel: () -> Bool
    ) async -> (text: String, model: any TranscriptionModel) {
        var text = text
        if streamed {
            text = await recoverTruncatedStream(
                text, audioURL: audioURL, model: configuration.model, context: context,
                shouldCancel: shouldCancel)
        }
        text = await recoverWrongLanguage(
            text, audioURL: audioURL, model: configuration.model, configuration: configuration,
            shouldCancel: shouldCancel)
        if let recovered = await recoverNonsense(
            text, audioURL: audioURL, configuration: configuration, shouldCancel: shouldCancel)
        {
            return recovered
        }
        return (text, configuration.model)
    }

    /// Retries the retained audio with each frozen keyboard language when the
    /// primary transcript lands outside the languages the user types.
    ///
    /// Runs only when the recording actually froze more than one candidate,
    /// which `KeyboardLanguagePolicy.recordingLanguages` reserves for
    /// follow-keyboard and auto-detect. An explicit language choice is never
    /// second-guessed.
    private func recoverWrongLanguage(
        _ text: String,
        audioURL: URL,
        model: any TranscriptionModel,
        configuration: TranscriptionRuntimeConfiguration,
        shouldCancel: () -> Bool
    ) async -> String {
        guard !configuration.recoveryCandidates.isEmpty else { return text }

        return await TranscriptLanguageRecovery.selectTranscript(
            primary: text,
            validationCandidates: configuration.languageCandidates,
            retryCandidates: configuration.recoveryCandidates
        ) { language in
            if shouldCancel() { throw CancellationError() }
            let attempt = try await transcribe(
                audioURL, model, TranscriptionRequestContext(language: language, prompt: nil))
            return TranscriptionOutputFilter.filter(attempt)
        }
    }

    /// Re-decodes the retained audio in one batch pass, same model and language,
    /// when a streaming transcript is too short for its recording. Returns the
    /// streamed text unless the retry carries more of the speech.
    private func recoverTruncatedStream(
        _ text: String,
        audioURL: URL,
        model: any TranscriptionModel,
        context: TranscriptionRequestContext,
        shouldCancel: () -> Bool
    ) async -> String {
        let duration = await audioDuration(audioURL)
        guard TranscriptTruncationDetector.isTruncated(text, audioDuration: duration),
            !shouldCancel()
        else { return text }

        Self.logger.notice(
            "Streamed transcript looks cut off (\(TranscriptTruncationDetector.letters(text), privacy: .public) letters in \(String(format: "%.1f", duration), privacy: .public)s); re-decoding in batch"
        )
        do {
            let attempt = TranscriptionOutputFilter.filter(try await transcribe(audioURL, model, context))
            guard TranscriptTruncationDetector.prefersRetry(attempt, over: text) else {
                Self.logger.notice("Batch re-decode was no longer; keeping the stream")
                return text
            }
            Self.logger.notice(
                "Replaced a cut-off stream with the batch re-decode (\(TranscriptTruncationDetector.letters(attempt), privacy: .public) letters)"
            )
            return attempt
        } catch {
            Self.logger.error("Batch re-decode failed: \(error.localizedDescription, privacy: .public)")
            return text
        }
    }

    /// Re-runs the retained audio through the recording's fallback model when
    /// the transcript reads as nonsense, and returns the fallback's transcript
    /// when it reads clearly better. Nil keeps the primary.
    private func recoverNonsense(
        _ text: String,
        audioURL: URL,
        configuration: TranscriptionRuntimeConfiguration,
        shouldCancel: () -> Bool
    ) async -> (text: String, model: any TranscriptionModel)? {
        guard let fallback = configuration.fallback else { return nil }

        let duration = await audioDuration(audioURL)
        let candidates = configuration.languageCandidates
        guard
            let reason = TranscriptNonsenseDetector.reason(
                for: text, audioDuration: duration, candidates: candidates, isMisspelled: isMisspelled)
        else { return nil }

        Self.logger.notice(
            "Transcript reads as nonsense (\(reason.rawValue, privacy: .public)); re-running with \(fallback.model.displayName, privacy: .public)"
        )
        guard !shouldCancel() else { return nil }

        do {
            let attempt = TranscriptionOutputFilter.filter(
                try await transcribe(
                    audioURL, fallback.model, TranscriptionRequestContext(language: fallback.language, prompt: nil)
                ))
            guard
                TranscriptNonsenseDetector.prefersFallback(
                    attempt, over: text, primaryReason: reason,
                    audioDuration: duration, candidates: candidates, isMisspelled: isMisspelled)
            else {
                Self.logger.notice("Fallback did not read better; keeping the primary")
                return nil
            }
            Self.logger.notice("Replaced a nonsense transcript with the fallback model's")
            return (attempt, fallback.model)
        } catch {
            Self.logger.error("Fallback transcription failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
