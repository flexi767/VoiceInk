import AppKit
import Foundation

/// Flags a transcript that reads as nonsense, so the pipeline can re-run the
/// retained audio through the recording's fallback model.
///
/// Like `TranscriptLanguageValidator`, this only ever triggers a retry. A false
/// positive costs one extra decode; the fallback replaces the primary only when
/// it reads clearly better (`prefersFallback`).
///
/// Runs after wrong-language recovery, so a transcript that still fails the
/// language check here is one no keyboard language could fix with this model.
enum TranscriptNonsenseDetector {

    enum Reason: String {
        /// A phrase looping back-to-back — Whisper's classic failure on noise.
        case repetition
        /// Subtitle credits Whisper emits for silence (`Untertitel im Auftrag des ZDF`).
        case subtitleHallucination
        /// More letters than anyone speaks in the recording's duration.
        case speakingRate
        /// Still outside the keyboard languages after recovery, or a word mixing scripts.
        case rejectedLanguage
        /// Most words are unknown to every keyboard language's dictionary.
        case misspelled

        /// Whether the text is broken outright, rather than merely
        /// suspicious. A fallback carrying one of these is never preferred.
        var isHard: Bool { self != .misspelled }
    }

    /// Below this many dictionary-checkable words the misspelling rule stays
    /// silent: one unknown name in a three-word dictation is half the text.
    static let minimumCheckedWords = 4

    /// Share of misspelled words at which a transcript reads as garbled.
    /// Real EN/DE/BG sentences sit at 0, Nemotron's garbled Bulgarian
    /// (`Лозън да фокус Мек ПСолд видеопла`) at 0.5 and above.
    static let misspelledThreshold = 0.5

    /// How much lower a fallback's misspelled share must be before it replaces
    /// a primary that was only suspicious.
    static let misspelledMargin = 0.25

    /// Letters per second of audio no speaker reaches; fast speech is ~15.
    /// The recording's duration includes its silences, so the real rate of a
    /// genuine transcript is only ever higher than this measures — never lower.
    static let maximumLettersPerSecond = 30.0

    private static let subtitleMarkers = [
        "amara org", "subtitles by", "thanks for watching", "thank you for watching",
        "untertitel im auftrag", "untertitelung", "vielen dank fürs zuschauen",
        "субтитр", "абонирайте се", "редактор субтитров",
    ]

    /// Spelling check for one word against candidate languages: true when every
    /// one of them rejects it. Injected so tests do not depend on the
    /// installed dictionaries.
    typealias MisspellingCheck = (_ word: String, _ languages: [String]) -> Bool

    static func reason(
        for text: String,
        audioDuration: TimeInterval,
        candidates: [String],
        isMisspelled: MisspellingCheck = systemIsMisspelled
    ) -> Reason? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let words = comparableWords(trimmed)
        if hasRepeatedPhrase(words) { return .repetition }

        let joined = words.joined(separator: " ")
        if subtitleMarkers.contains(where: { joined.contains($0) }) { return .subtitleHallucination }

        let letters = trimmed.unicodeScalars.filter { $0.properties.isAlphabetic }.count
        if audioDuration >= 1, letters >= 40,
            Double(letters) / audioDuration > maximumLettersPerSecond
        {
            return .speakingRate
        }

        let languages = spokenLanguages(candidates)
        if !languages.isEmpty, !TranscriptLanguageValidator.accepts(trimmed, candidates: languages) {
            return .rejectedLanguage
        }

        if let ratio = misspelledRatio(trimmed, candidates: languages, isMisspelled: isMisspelled),
            ratio.checked >= minimumCheckedWords, ratio.value >= misspelledThreshold
        {
            return .misspelled
        }
        return nil
    }

    /// Whether the fallback transcript should replace a primary flagged for
    /// `primaryReason`. An empty or itself-broken fallback never does; against a
    /// merely misspelled primary it must also be clearly better spelled.
    static func prefersFallback(
        _ fallback: String,
        over primary: String,
        primaryReason: Reason,
        audioDuration: TimeInterval,
        candidates: [String],
        isMisspelled: MisspellingCheck = systemIsMisspelled
    ) -> Bool {
        guard !fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }

        let fallbackReason = reason(
            for: fallback, audioDuration: audioDuration, candidates: candidates,
            isMisspelled: isMisspelled)
        if fallbackReason?.isHard == true { return false }
        if primaryReason.isHard { return true }

        let languages = spokenLanguages(candidates)
        guard
            let primaryRatio = misspelledRatio(
                primary, candidates: languages, isMisspelled: isMisspelled)?.value,
            let fallbackRatio = misspelledRatio(
                fallback, candidates: languages, isMisspelled: isMisspelled)?.value
        else { return false }
        return fallbackRatio <= primaryRatio - misspelledMargin
    }

    // MARK: - Signals

    /// A block of 1–8 words repeated back-to-back: five times for a single
    /// word, four for a phrase. Dictation repeats a word for emphasis
    /// (`test test test`) but not a phrase four times running.
    static func hasRepeatedPhrase(_ words: [String]) -> Bool {
        guard words.count >= 5 else { return false }

        for length in 1...min(8, words.count / 4) {
            let required = length == 1 ? 5 : 4
            var start = 0
            while start + length * required <= words.count {
                let block = words[start..<start + length]
                var repeats = 1
                var next = start + length
                while next + length <= words.count, words[next..<next + length] == block {
                    repeats += 1
                    next += length
                }
                if repeats >= required { return true }
                start += 1
            }
        }
        return false
    }

    /// The share of words every candidate language's dictionary rejects, and
    /// how many words were checked. Single letters are skipped: Bulgarian `и`
    /// and `в` are words, and so is any stray initial.
    static func misspelledRatio(
        _ text: String,
        candidates: [String],
        isMisspelled: MisspellingCheck
    ) -> (value: Double, checked: Int)? {
        let bases = Array(Set(candidates.compactMap { KeyboardLanguagePolicy.baseSubtag($0) }))
        guard !bases.isEmpty else { return nil }

        let words = letterRuns(text).filter { $0.count > 1 }
        guard !words.isEmpty else { return nil }

        let misspelled = words.filter { isMisspelled($0, bases) }.count
        return (Double(misspelled) / Double(words.count), words.count)
    }

    /// Candidate languages with the sentinels removed: auto-detect is not a
    /// language a transcript can be in.
    private static func spokenLanguages(_ candidates: [String]) -> [String] {
        candidates.filter {
            $0 != KeyboardLanguagePolicy.autoDetectCode && $0 != KeyboardLanguagePolicy.followKeyboardCode
        }
    }

    private static func letterRuns(_ text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter }).map(String.init)
    }

    private static func comparableWords(_ text: String) -> [String] {
        letterRuns(text.lowercased())
    }

    // MARK: - System dictionaries

    /// `NSSpellChecker` against each base language that has an installed
    /// dictionary. A word passes when any of them knows it, so English terms in
    /// Bulgarian dictation are not counted. With no dictionary at all, nothing
    /// is misspelled — the rule fails open.
    static func systemIsMisspelled(_ word: String, languages: [String]) -> Bool {
        let checker = NSSpellChecker.shared
        let available = Set(checker.availableLanguages)
        let usable = languages.filter { available.contains($0) }
        guard !usable.isEmpty else { return false }

        return usable.allSatisfy { language in
            checker.checkSpelling(
                of: word, startingAt: 0, language: language, wrap: false,
                inSpellDocumentWithTag: 0, wordCount: nil
            ).location != NSNotFound
        }
    }
}
