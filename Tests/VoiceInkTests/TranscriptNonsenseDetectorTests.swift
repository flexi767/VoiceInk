import Testing

@testable import VoiceInk

/// Covers the nonsense signals and the fallback preference with an injected
/// spelling check, so results do not depend on the installed dictionaries.
struct TranscriptNonsenseDetectorTests {

    private typealias Detector = TranscriptNonsenseDetector

    private static let candidates = ["bg", "de", "en"]

    /// Treats only the listed words as misspelled.
    private static func misspelled(_ words: Set<String>) -> Detector.MisspellingCheck {
        { word, _ in words.contains(word) }
    }

    private static let nothingMisspelled: Detector.MisspellingCheck = { _, _ in false }

    private func reason(
        _ text: String, duration: Double = 5, check: Detector.MisspellingCheck = nothingMisspelled
    ) -> Detector.Reason? {
        Detector.reason(
            for: text, audioDuration: duration, candidates: Self.candidates, isMisspelled: check)
    }

    // MARK: - Plausible dictation

    @Test func acceptsOrdinaryDictation() {
        #expect(reason("Диктувам на български и искам да видя дали работи.") == nil)
        #expect(reason("Ich dachte, es ist lang genug für heute.") == nil)
        #expect(reason("Let's give it another shot.") == nil)
        #expect(reason("") == nil)
    }

    @Test func allowsEmphaticRepetition() {
        #expect(reason("Test test test, can you hear me?") == nil)
        #expect(reason("No, no, no, that is not what I meant.") == nil)
    }

    // MARK: - Signals

    @Test func flagsLoopingPhrase() {
        #expect(reason("Thank you very much. Thank you very much. Thank you very much. Thank you very much.") == .repetition)
        #expect(reason("и и и и и") == .repetition)
        #expect(Detector.hasRepeatedPhrase(["a", "b", "a", "b", "a", "b"]) == false)
        #expect(Detector.hasRepeatedPhrase(["x", "a", "b", "a", "b", "a", "b", "a", "b"]))
    }

    @Test func flagsSubtitleCredits() {
        #expect(reason("Untertitel im Auftrag des ZDF, 2021") == .subtitleHallucination)
        #expect(reason("Subtitles by the Amara.org community") == .subtitleHallucination)
        #expect(reason("Абонирайте се за канала!") == .subtitleHallucination)
    }

    @Test func flagsImpossibleSpeakingRate() {
        let text = "This sentence has far too many letters for a one second clip of audio."
        #expect(reason(text, duration: 1) == .speakingRate)
        #expect(reason(text, duration: 6) == nil)
    }

    @Test func flagsMixedScriptWord() {
        #expect(reason("Iс-Terme that speaks to me") == .rejectedLanguage)
    }

    @Test func flagsMostlyMisspelledText() {
        let garbled = "Лозън да фокус Мек ПСолд видеопла"
        let check = Self.misspelled(["Лозън", "Мек", "ПСолд", "видеопла"])
        #expect(reason(garbled, check: check) == .misspelled)
    }

    @Test func toleratesAFewUnknownWords() {
        // One unknown name, and a short dictation that is too little to judge.
        #expect(reason("Пуснах Cotabby на новия лаптоп днес", check: Self.misspelled(["Cotabby"])) == nil)
        #expect(reason("Мек ПСолд", check: Self.misspelled(["Мек", "ПСолд"])) == nil)
    }

    @Test func skipsSingleLetterWords() {
        let ratio = Detector.misspelledRatio(
            "и в Лозън", candidates: Self.candidates, isMisspelled: Self.misspelled(["Лозън"]))
        #expect(ratio?.checked == 1)
        #expect(ratio?.value == 1)
    }

    // MARK: - Fallback preference

    @Test func prefersAnyCleanFallbackOverABrokenPrimary() {
        let prefers = Detector.prefersFallback(
            "Диктувам на български.", over: "и и и и и", primaryReason: .repetition,
            audioDuration: 5, candidates: Self.candidates, isMisspelled: Self.nothingMisspelled)
        #expect(prefers)
    }

    @Test func neverPrefersAnEmptyOrBrokenFallback() {
        #expect(
            !Detector.prefersFallback(
                "  ", over: "и и и и и", primaryReason: .repetition,
                audioDuration: 5, candidates: Self.candidates, isMisspelled: Self.nothingMisspelled))
        #expect(
            !Detector.prefersFallback(
                "Thanks for watching!", over: "и и и и и", primaryReason: .repetition,
                audioDuration: 5, candidates: Self.candidates, isMisspelled: Self.nothingMisspelled))
    }

    @Test func requiresAClearlyBetterSpelledFallbackForAMisspelledPrimary() {
        let check = Self.misspelled(["Лозън", "Мек", "ПСолд", "видеопла", "Лозен", "видеоплан"])
        let primary = "Лозън да фокус Мек ПСолд видеопла"  // 4 of 6

        #expect(
            Detector.prefersFallback(
                "Ловен да фокусирам мека подложка видео", over: primary, primaryReason: .misspelled,
                audioDuration: 5, candidates: Self.candidates, isMisspelled: check))
        // 3 of 6: better, but not by the margin.
        #expect(
            !Detector.prefersFallback(
                "Лозен да фокус Мек подложка видеоплан", over: primary, primaryReason: .misspelled,
                audioDuration: 5, candidates: Self.candidates, isMisspelled: check))
    }
}
