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

    /// How confidently `text` reads as one of `candidates`: the strongest
    /// hypothesis's probability, or 0 when the strongest sits outside the set.
    /// Used to rank competing transcripts rather than to accept or reject one.
    static func candidateConfidence(_ text: String, candidates: [String]) -> Double {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }

        let bases = Set(candidates.compactMap { KeyboardLanguagePolicy.baseSubtag($0) })
        guard !bases.isEmpty else { return 0 }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        guard let strongest = recognizer.languageHypotheses(withMaximum: 1)
            .max(by: { $0.value < $1.value })
        else { return 0 }

        return bases.contains(base(of: strongest.key.rawValue)) ? strongest.value : 0
    }

    // MARK: - Script awareness

    /// The writing system a language is normally rendered in.
    ///
    /// Everything not listed is treated as Latin, which is the safe default: the
    /// script rules below only ever *add* suspicion for non-Latin candidates, so
    /// an unknown language can never trigger a spurious retry.
    static func expectedScript(forBaseSubtag subtag: String) -> String {
        switch subtag {
        case "bg", "ru", "uk", "mk", "sr", "be": return "Cyrillic"
        case "ja": return "Kana"
        case "ko": return "Hangul"
        case "zh": return "Han"
        case "hi": return "Devanagari"
        case "ar", "fa", "ur": return "Arabic"
        case "el": return "Greek"
        case "he", "yi": return "Hebrew"
        default: return "Latin"
        }
    }

    /// The scripts present among the alphabetic characters of `text`.
    static func scripts(in text: String) -> Set<String> {
        var found: Set<String> = []
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            switch scalar.value {
            case 0x0400...0x052F, 0x1C80...0x1C8F, 0x2DE0...0x2DFF, 0xA640...0xA69F:
                found.insert("Cyrillic")
            case 0x0041...0x005A, 0x0061...0x007A, 0x00C0...0x024F, 0x1E00...0x1EFF:
                found.insert("Latin")
            case 0x3040...0x30FF: found.insert("Kana")
            case 0x4E00...0x9FFF, 0x3400...0x4DBF: found.insert("Han")
            case 0xAC00...0xD7AF, 0x1100...0x11FF: found.insert("Hangul")
            case 0x0900...0x097F: found.insert("Devanagari")
            case 0x0600...0x06FF, 0x0750...0x077F: found.insert("Arabic")
            case 0x0370...0x03FF, 0x1F00...0x1FFF: found.insert("Greek")
            case 0x0590...0x05FF: found.insert("Hebrew")
            default: break
            }
        }
        return found
    }

    /// Candidates whose script never appears in the primary transcript — a
    /// Cyrillic `bg-BG` against an all-Latin transcript, for instance. These are
    /// the languages worth probing, which keeps the extra inference to one or
    /// two retries instead of the whole candidate list.
    static func scriptMismatchedCandidates(_ candidates: [String], primary: String) -> [String] {
        let present = scripts(in: primary)
        return candidates.filter { candidate in
            guard let subtag = KeyboardLanguagePolicy.baseSubtag(candidate) else { return false }
            let expected = expectedScript(forBaseSubtag: subtag)
            return expected != "Latin" && !present.contains(expected)
        }
    }

    /// Whether the primary looks like a transliteration of a language the user
    /// types but which never appeared in its own script.
    ///
    /// This is the case `accepts` cannot see. Handed the wrong language, the
    /// model romanises rather than fails: Bulgarian dictated on a Latin layout
    /// comes back as `Diktur na Bulgarski`, which Apple's recogniser is happy to
    /// call valid — so recovery never fires and the dictation is quietly wrong.
    ///
    /// Gated on confidence so that genuinely confident Latin dictation, with a
    /// Cyrillic keyboard merely installed, is not dragged into a retry.
    static func scriptMismatchSuspected(
        _ text: String,
        candidates: [String],
        confidenceFloor: Double = 0.85
    ) -> Bool {
        guard candidateConfidence(text, candidates: candidates) < confidenceFloor,
            !scripts(in: text).isEmpty
        else { return false }

        return !scriptMismatchedCandidates(candidates, primary: text).isEmpty
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

    /// Margin a probe must beat the primary by before replacing it.
    ///
    /// Applies only to the *suspected transliteration* case, where the primary
    /// was accepted and we are second-guessing it. Without the margin, genuine
    /// Latin-script dictation gets over-converted into Cyrillic the moment a
    /// Cyrillic keyboard is installed.
    private static let transliterationMargin = 0.15

    /// Retry order: candidates whose script is missing from the primary first —
    /// the most likely missed language — and English always last, because
    /// forcing English yields fluent English that validates for almost any audio
    /// and would mask a correct result from another candidate.
    static func retryOrder(_ candidates: [String], primary: String) -> [String] {
        let mismatched = Set(
            TranscriptLanguageValidator.scriptMismatchedCandidates(candidates, primary: primary))

        return candidates.enumerated().sorted { lhs, rhs in
            let lhsEnglish = KeyboardLanguagePolicy.baseSubtag(lhs.element) == "en"
            let rhsEnglish = KeyboardLanguagePolicy.baseSubtag(rhs.element) == "en"
            if lhsEnglish != rhsEnglish { return rhsEnglish }

            let lhsMismatched = mismatched.contains(lhs.element)
            let rhsMismatched = mismatched.contains(rhs.element)
            if lhsMismatched != rhsMismatched { return lhsMismatched }

            return lhs.offset < rhs.offset
        }.map { $0.element }
    }

    /// Returns the transcript to keep.
    ///
    /// The primary is returned untouched whenever it validates and looks like
    /// the script it should, whenever no retry validates, and whenever every
    /// retry fails — a dictation is never lost to this path.
    ///
    /// Two different triggers, with different burdens of proof:
    ///
    /// - **Rejected** — the primary is empty or confidently outside the user's
    ///   languages. Any validated retry is an improvement.
    /// - **Suspect** — the primary was accepted but a candidate's script never
    ///   appeared, so it may be a romanisation. A retry has to read clearly
    ///   better before it replaces something already plausible.
    ///
    /// - Parameters:
    ///   - validationCandidates: every language frozen for the recording,
    ///     *including* the one the primary pass ran with. Validating against the
    ///     retry list alone would reject every correct transcript, since a
    ///     transcript in the primary language is by definition not in any of the
    ///     fallbacks.
    ///   - retryCandidates: the languages to re-run the retained audio with.
    static func selectTranscript(
        primary: String,
        validationCandidates: [String],
        retryCandidates: [String],
        retry: (String) async throws -> String
    ) async -> String {
        guard !retryCandidates.isEmpty else { return primary }

        let isEmpty = primary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let accepted =
            !isEmpty
            && TranscriptLanguageValidator.accepts(primary, candidates: validationCandidates)
        let suspect =
            !isEmpty
            && TranscriptLanguageValidator.scriptMismatchSuspected(
                primary, candidates: validationCandidates)

        guard !accepted || suspect else { return primary }

        let ordered = retryOrder(retryCandidates, primary: primary)
        logger.notice(
            "Primary is \(accepted ? "a suspected transliteration" : "empty or outside the keyboard languages", privacy: .public); probing \(ordered.count, privacy: .public) candidate(s)"
        )

        // Every candidate is probed and the best-reading result wins, rather than
        // the first that merely validates: with two or three keyboards the extra
        // inference is cheap, and "validates" is a much weaker bar than "reads
        // best", which is the whole point when the primary already looked fine.
        var best: (text: String, score: Double)?

        for candidate in ordered {
            do {
                let attempt = try await retry(candidate)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !attempt.isEmpty else {
                    logger.notice("Forced \(candidate, privacy: .public) returned nothing")
                    continue
                }
                // Validated against the single language it was forced to, not the
                // whole set: a retry that drifted back to the wrong language must
                // not pass just because some other keyboard would explain it.
                guard TranscriptLanguageValidator.accepts(attempt, candidates: [candidate]) else {
                    logger.notice("Forced \(candidate, privacy: .public) did not validate")
                    continue
                }
                let score = TranscriptLanguageValidator.candidateConfidence(
                    attempt, candidates: validationCandidates)
                if best == nil || score > best!.score {
                    best = (attempt, score)
                }
            } catch is CancellationError {
                return primary
            } catch {
                logger.error(
                    "Forced \(candidate, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        guard let best else {
            logger.warning("No candidate validated; preserving the primary transcript")
            return primary
        }

        guard accepted else {
            logger.notice("Recovered a rejected dictation from a forced retry")
            return best.text
        }

        let primaryScore = TranscriptLanguageValidator.candidateConfidence(
            primary, candidates: validationCandidates)
        guard best.score > primaryScore + transliterationMargin else {
            logger.notice("No probe beat the primary by the margin; keeping it")
            return primary
        }

        logger.notice("Replaced a suspected transliteration with a better-reading retry")
        return best.text
    }
}
