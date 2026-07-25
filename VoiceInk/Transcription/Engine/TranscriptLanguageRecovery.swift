import Foundation
import NaturalLanguage
import os

/// Decides whether a transcript is plausibly in one of the languages the user
/// actually types.
///
/// Evidence, not certainty: this only ever *triggers* a retry, and every
/// ambiguous case fails open so a valid transcript is never thrown away. Mixed
/// language is legitimate — `OpenAI тест` must pass — so the rule is that a
/// confidently detected span must be explainable by an enabled language, not
/// that the whole transcript uses one script.
enum TranscriptLanguageValidator {

    /// Probability mass that must sit outside the candidate set before a
    /// transcript is called wrong-language.
    private static let outsideMassThreshold = 0.85

    /// Confidence at which a single top hypothesis is decisive on its own.
    /// Only applied to multi-word text; one word is too noisy for it.
    private static let dominantHypothesisThreshold = 0.90

    private static let maximumHypotheses = 5

    static func accepts(_ text: String, candidates: [String]) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        let bases = Set(candidates.compactMap { KeyboardLanguagePolicy.baseSubtag($0) })
        guard !bases.isEmpty else { return true }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        let hypotheses = recognizer.languageHypotheses(withMaximum: maximumHypotheses)
        guard !hypotheses.isEmpty else { return true }

        var outsideMass = 0.0
        for (language, probability) in hypotheses
        where !bases.contains(base(of: language.rawValue)) {
            outsideMass += probability
        }
        if outsideMass >= outsideMassThreshold { return false }

        // A single word carries too little signal for the dominance rule —
        // names like `Alice` or `OpenAI` would be rejected constantly.
        let isSingleWord = trimmed.split(whereSeparator: { $0.isWhitespace }).count < 2
        guard !isSingleWord,
            let top = hypotheses.max(by: { $0.value < $1.value }),
            top.value >= dominantHypothesisThreshold
        else { return true }

        return bases.contains(base(of: top.key.rawValue))
    }

    private static func base(of identifier: String) -> String {
        KeyboardLanguagePolicy.baseSubtag(identifier) ?? identifier.lowercased()
    }
}

/// Retries a wrong-language dictation against the user's other keyboard
/// languages, using the audio already on disk.
enum TranscriptLanguageRecovery {

    private static let logger = Logger(
        subsystem: "com.prakashjoshipax.voiceink", category: "TranscriptLanguageRecovery")

    /// Returns the transcript to keep.
    ///
    /// The primary is returned untouched whenever it validates, whenever no
    /// retry validates, and whenever every retry fails — a dictation is never
    /// lost to this path. Only a retry that is both non-empty *and* valid for
    /// the language it was forced to can replace it.
    /// - Parameters:
    ///   - validationCandidates: every language frozen for the recording,
    ///     *including* the one the primary pass ran with. Validating against the
    ///     retry list alone would reject every correct transcript, since a
    ///     transcript in the primary language is by definition not in any of the
    ///     fallbacks.
    ///   - retryCandidates: the languages to re-run the retained audio with, in
    ///     order.
    static func selectTranscript(
        primary: String,
        validationCandidates: [String],
        retryCandidates: [String],
        retry: (String) async throws -> String
    ) async -> String {
        guard !retryCandidates.isEmpty else { return primary }

        let primaryIsEmpty = primary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard primaryIsEmpty
            || !TranscriptLanguageValidator.accepts(primary, candidates: validationCandidates)
        else {
            return primary
        }

        logger.notice(
            "Primary transcript is empty or outside the keyboard languages; trying \(retryCandidates.count, privacy: .public) candidate(s)"
        )

        for candidate in retryCandidates {
            do {
                let attempt = try await retry(candidate)
                let trimmed = attempt.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    logger.notice("Forced \(candidate, privacy: .public) returned nothing; next candidate")
                    continue
                }
                // Validate against the single language it was forced to, not the
                // whole candidate set: a retry that drifted back to the wrong
                // language must not be accepted just because some other keyboard
                // would have explained it.
                guard TranscriptLanguageValidator.accepts(trimmed, candidates: [candidate]) else {
                    logger.notice("Forced \(candidate, privacy: .public) did not validate; next candidate")
                    continue
                }
                logger.notice("Recovered dictation by forcing \(candidate, privacy: .public)")
                return trimmed
            } catch is CancellationError {
                return primary
            } catch {
                logger.error(
                    "Forced \(candidate, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        logger.warning("No candidate validated; preserving the primary transcript")
        return primary
    }
}
