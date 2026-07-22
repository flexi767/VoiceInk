import Foundation
import NaturalLanguage

/// Offline evidence used to decide whether retained audio needs a forced-language retry.
enum TranscriptLanguageValidator {
    private static let confidentMismatchThreshold = 0.90
    private static let outsideCandidateThreshold = 0.85

    static func accepts(_ rawText: String, expectedLanguage: String, candidates: [String]) -> Bool {
        let words = words(in: rawText)
        guard !words.isEmpty,
            let expected = KeyboardLanguagePolicy.primaryLanguageSubtag(expectedLanguage)
        else { return false }

        let candidateBases = Set(candidates.compactMap(KeyboardLanguagePolicy.primaryLanguageSubtag))
        guard !candidateBases.isEmpty else { return true }

        let wholeHypotheses = hypotheses(for: words.joined(separator: " "), maximum: 5)
        let outsideProbability = wholeHypotheses.reduce(0.0) { total, hypothesis in
            candidateBases.contains(hypothesis.language) ? total : total + hypothesis.confidence
        }

        // One word cannot establish a reliable positive language identity. It
        // can still provide strong negative evidence when virtually every
        // plausible language is outside the user's enabled candidates.
        if words.count == 1 {
            return outsideProbability < outsideCandidateThreshold
        }

        if outsideProbability >= outsideCandidateThreshold { return false }
        if let strongest = wholeHypotheses.first,
            strongest.confidence >= confidentMismatchThreshold,
            strongest.language != expected
        {
            return false
        }

        // A confident unsupported two-word span catches mixed hallucinations;
        // isolated brands and supported code-switching remain allowed.
        for index in 0..<(words.count - 1) {
            let span = "\(words[index]) \(words[index + 1])"
            guard let strongest = hypotheses(for: span, maximum: 1).first else { continue }
            if strongest.confidence >= confidentMismatchThreshold,
                !candidateBases.contains(strongest.language)
            {
                return false
            }
        }

        return true
    }

    static func outsideCandidateProbability(for rawText: String, candidates: [String]) -> Double? {
        let words = words(in: rawText)
        guard words.count == 1 else { return nil }
        let candidateBases = Set(candidates.compactMap(KeyboardLanguagePolicy.primaryLanguageSubtag))
        guard !candidateBases.isEmpty else { return nil }
        return hypotheses(for: words[0], maximum: 5).reduce(0.0) { total, hypothesis in
            candidateBases.contains(hypothesis.language) ? total : total + hypothesis.confidence
        }
    }

    private static func words(in text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter }).map(String.init)
    }

    private static func hypotheses(for text: String, maximum: Int) -> [(language: String, confidence: Double)] {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.languageHypotheses(withMaximum: maximum)
            .compactMap { language, confidence in
                guard let base = KeyboardLanguagePolicy.primaryLanguageSubtag(language.rawValue) else {
                    return nil
                }
                return (base, confidence)
            }
            .sorted { $0.confidence > $1.confidence }
    }
}

enum TranscriptLanguageRecovery {
    /// Selects a validated transcript while preserving the primary result when
    /// no retry succeeds. The caller supplies the retained-audio inference.
    static func selectTranscript(
        primary rawPrimary: String,
        candidates: [String],
        retry: (String) async throws -> String
    ) async -> String {
        let primary = TranscriptionOutputFilter.filter(rawPrimary)
        guard let primaryLanguage = candidates.first else { return primary }

        if TranscriptLanguageValidator.accepts(
            primary, expectedLanguage: primaryLanguage, candidates: candidates)
        {
            return primary
        }

        for language in candidates {
            guard !Task.isCancelled else { return primary }
            do {
                let candidate = TranscriptionOutputFilter.filter(try await retry(language))
                if TranscriptLanguageValidator.accepts(
                    candidate, expectedLanguage: language, candidates: candidates)
                {
                    return candidate
                }
            } catch is CancellationError {
                return primary
            } catch {
                continue
            }
        }

        return primary
    }
}
