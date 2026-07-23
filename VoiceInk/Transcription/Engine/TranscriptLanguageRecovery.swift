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

    // MARK: - Script-aware recovery signals

    /// The confidence that `text` reads as one of the user's candidate languages
    /// (0 when the strongest hypothesis is outside the candidate set). Used to tell
    /// a confident dictation apart from an ambiguous transliteration.
    static func candidateConfidence(_ text: String, candidates: [String]) -> Double {
        let words = words(in: text)
        guard !words.isEmpty else { return 0 }
        let bases = Set(candidates.compactMap(KeyboardLanguagePolicy.primaryLanguageSubtag))
        guard let strongest = hypotheses(for: words.joined(separator: " "), maximum: 1).first else { return 0 }
        return bases.contains(strongest.language) ? strongest.confidence : 0
    }

    /// The writing system a language is normally rendered in. Nemotron transliterates
    /// into Latin when it is handed the wrong language, so a Cyrillic/CJK/etc. candidate
    /// whose script is absent from the primary is strong evidence of a missed language.
    static func expectedScript(forPrimarySubtag subtag: String) -> String {
        switch subtag {
        case "bg", "ru", "uk", "mk", "sr", "be": return "Cyrillic"
        case "ja": return "Kana"
        case "ko": return "Hangul"
        case "zh": return "Han"
        case "hi": return "Devanagari"
        case "ar": return "Arabic"
        default: return "Latin"
        }
    }

    /// The set of scripts present among the alphabetic characters of `text`.
    static func scripts(in text: String) -> Set<String> {
        var result: Set<String> = []
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            switch scalar.value {
            case 0x0400...0x052F, 0x1C80...0x1C8F, 0x2DE0...0x2DFF, 0xA640...0xA69F: result.insert("Cyrillic")
            case 0x0041...0x005A, 0x0061...0x007A, 0x00C0...0x024F, 0x1E00...0x1EFF: result.insert("Latin")
            case 0x3040...0x30FF: result.insert("Kana")
            case 0x4E00...0x9FFF, 0x3400...0x4DBF: result.insert("Han")
            case 0xAC00...0xD7AF, 0x1100...0x11FF: result.insert("Hangul")
            case 0x0900...0x097F: result.insert("Devanagari")
            case 0x0600...0x06FF, 0x0750...0x077F: result.insert("Arabic")
            default: break
            }
        }
        return result
    }

    /// True when the primary transcript is not confidently one of the candidate
    /// languages AND at least one candidate expects a script the primary never
    /// produced. This is the case the offline validator misses: short romanized
    /// Bulgarian passes `accepts` yet a Cyrillic keyboard is enabled and was never tried.
    static func scriptMismatchSuspected(
        _ text: String,
        candidates: [String],
        confidenceFloor: Double = 0.85
    ) -> Bool {
        guard candidateConfidence(text, candidates: candidates) < confidenceFloor else { return false }
        let present = scripts(in: text)
        guard !present.isEmpty else { return false }
        for candidate in candidates {
            guard let subtag = KeyboardLanguagePolicy.primaryLanguageSubtag(candidate) else { continue }
            let expected = expectedScript(forPrimarySubtag: subtag)
            if expected != "Latin", !present.contains(expected) { return true }
        }
        return false
    }

    /// The subset of candidates whose expected script never appears in the primary
    /// transcript (e.g. a Cyrillic `bg-BG` when the primary is all-Latin). These are
    /// the only languages worth probing when the primary was accepted but looks like a
    /// possible transliteration — it keeps the extra inference cost to one or two retries.
    static func scriptMismatchedCandidates(_ candidates: [String], primary: String) -> [String] {
        let present = scripts(in: primary)
        return candidates.filter { code in
            guard let subtag = KeyboardLanguagePolicy.primaryLanguageSubtag(code) else { return false }
            let expected = expectedScript(forPrimarySubtag: subtag)
            return expected != "Latin" && !present.contains(expected)
        }
    }

    /// Orders candidates so those whose expected script is absent from the primary
    /// come first — the most likely missed language is retried before re-confirming
    /// the script the primary already produced.
    static func scriptPreferredOrder(_ candidates: [String], primary: String) -> [String] {
        let mismatched = Set(scriptMismatchedCandidates(candidates, primary: primary))
        return candidates.enumerated().sorted { lhs, rhs in
            let l = mismatched.contains(lhs.element), r = mismatched.contains(rhs.element)
            if l != r { return l }          // script-mismatched candidates first
            return lhs.offset < rhs.offset  // otherwise keep original order (stable)
        }.map { $0.element }
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

        let accepted = TranscriptLanguageValidator.accepts(
            primary, expectedLanguage: primaryLanguage, candidates: candidates)
        // The offline validator green-lights short romanized transcripts (e.g. Bulgarian
        // dictated on a Latin keyboard), skipping recovery entirely. Force the retry pass
        // when a candidate expects a script the primary never produced.
        let scriptSuspect = TranscriptLanguageValidator.scriptMismatchSuspected(
            primary, candidates: candidates)

        if accepted && !scriptSuspect {
            return primary
        }

        // Both a rejected primary and an accepted-but-suspect one re-check the other
        // candidate languages (the primary language already produced this transcript, so
        // re-running it is redundant), most-likely-missed script first.
        let retryLanguages = TranscriptLanguageValidator
            .scriptPreferredOrder(candidates, primary: primary)
            .filter { $0 != primaryLanguage }
        var best: (text: String, score: Double)?

        for language in retryLanguages {
            guard !Task.isCancelled else { break }
            do {
                let candidate = TranscriptionOutputFilter.filter(try await retry(language))
                guard TranscriptLanguageValidator.accepts(
                    candidate, expectedLanguage: language, candidates: candidates)
                else { continue }
                let score = TranscriptLanguageValidator.candidateConfidence(
                    candidate, candidates: candidates)
                if best == nil || score > best!.score {
                    best = (candidate, score)
                }
            } catch is CancellationError {
                break
            } catch {
                continue
            }
        }

        guard let best else { return primary }
        // Primary was rejected outright → any validated retry is an improvement.
        // Primary was accepted-but-suspect → only replace it when a retry reads
        // clearly better, so genuine Latin-script dictation is never over-converted.
        if !accepted {
            return best.text
        }
        let primaryScore = TranscriptLanguageValidator.candidateConfidence(primary, candidates: candidates)
        return best.score > primaryScore + 0.15 ? best.text : primary
    }
}
