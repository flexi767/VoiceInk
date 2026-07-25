import Testing

@testable import VoiceInk

/// Covers the pure parts of keyboard-language routing: locale matching,
/// candidate ordering, and the rules that keep a keyboard-derived language from
/// reaching a model that would mishandle it.
///
/// The Carbon input-source reads are excluded on purpose — they need a real
/// window server — so `orderedLanguages` is exercised through injected sources.
struct KeyboardLanguagePolicyTests {

    private typealias Policy = KeyboardLanguagePolicy
    private typealias Source = KeyboardLanguagePolicy.InputSource

    private static let nemotron = TranscriptionModelRegistry.models
        .first { $0.name == "nemotron-multilingual-0.6b" }!
    private static let parakeetV3 = TranscriptionModelRegistry.models
        .first { $0.name == "parakeet-tdt-0.6b-v3" }!

    // MARK: - Locale matching

    @Test func matchesModelLocaleOnBaseSubtag() {
        // A `bg` keyboard must reach a model advertising `bg-BG`; exact string
        // equality silently skipped every candidate in the previous attempt.
        #expect(Policy.matchingSupportedLanguage("bg", supported: ["bg-BG", "en-US"]) == "bg-BG")
        #expect(Policy.matchingSupportedLanguage("bg-BG", supported: ["bg-BG"]) == "bg-BG")
        #expect(Policy.matchingSupportedLanguage("de-AT", supported: ["de-DE"]) == "de-DE")
        #expect(Policy.matchingSupportedLanguage("ja", supported: ["bg-BG", "en-US"]) == nil)
    }

    @Test func prefersExactMatchOverBaseSubtag() {
        #expect(Policy.matchingSupportedLanguage("pt-BR", supported: ["pt-BR", "pt-PT"]) == "pt-BR")
    }

    @Test func normalizesUnderscoreIdentifiers() {
        #expect(Policy.matchingSupportedLanguage("bg_BG", supported: ["bg-BG"]) == "bg-BG")
    }

    // MARK: - Ordering

    @Test func putsActiveKeyboardFirstAndDeduplicatesByBaseSubtag() {
        let ordered = Policy.orderedLanguages(
            active: Source(languages: ["bg"], localizedName: "Bulgarian"),
            enabled: [
                Source(languages: ["en-GB"], localizedName: "British"),
                Source(languages: ["en-US"], localizedName: "U.S."),
                Source(languages: ["de"], localizedName: "German"),
            ],
            supported: ["bg-BG", "en-US", "de-DE"]
        )
        // `en` appears twice among the layouts but must yield one candidate.
        #expect(ordered == ["bg-BG", "en-US", "de-DE"])
    }

    @Test func ignoresKeyboardsTheModelDoesNotSupport() {
        let ordered = Policy.orderedLanguages(
            active: Source(languages: ["ja"], localizedName: "Japanese"),
            enabled: [Source(languages: ["en-US"], localizedName: "U.S.")],
            supported: ["en-US", "de-DE"]
        )
        #expect(ordered == ["en-US"])
    }

    @Test func fallsBackToLayoutNameOnlyWhenMetadataIsAbsent() {
        let named = Policy.language(
            for: Source(languages: [], localizedName: "German"),
            supported: ["de-DE", "en-US"]
        )
        #expect(named == "de-DE")

        // Metadata is authoritative: a misleading name must not override it.
        let metadata = Policy.language(
            for: Source(languages: ["en-US"], localizedName: "German"),
            supported: ["de-DE", "en-US"]
        )
        #expect(metadata == "en-US")
    }

    // MARK: - Recovery ordering

    @Test func triesEnglishLast() {
        // Forcing English on non-English audio yields fluent English that always
        // validates, masking a correct result from another candidate.
        #expect(Policy.recoveryOrder(["en-US", "bg-BG", "de-DE"]) == ["bg-BG", "de-DE", "en-US"])
        #expect(Policy.recoveryOrder(["bg-BG"]) == ["bg-BG"])
        #expect(Policy.recoveryOrder([]).isEmpty)
    }

    // MARK: - Capability gating

    @Test func onlyOffersFollowKeyboardWhereLanguageIsARealHint() {
        #expect(Policy.supportsFollowKeyboard(for: Self.nemotron))
        // Parakeet's `Language` is a Unicode script filter over the decoder's
        // argmax, not a language lock; forcing one deletes tokens in the wrong
        // script, the leading word included.
        #expect(!Policy.supportsFollowKeyboard(for: Self.parakeetV3))
    }

    @Test func neverHandsTheSentinelToAModel() {
        let candidates = Policy.recordingLanguages(
            configuredLanguage: Policy.followKeyboardCode,
            for: Self.nemotron
        )
        #expect(!candidates.isEmpty)
        #expect(!candidates.contains(Policy.followKeyboardCode))

        // A model that cannot use the sentinel must not be handed it either.
        let parakeet = Policy.recordingLanguages(
            configuredLanguage: Policy.followKeyboardCode,
            for: Self.parakeetV3
        )
        #expect(!parakeet.contains(Policy.followKeyboardCode))
        #expect(Policy.resolvedLanguage(Policy.followKeyboardCode, for: Self.parakeetV3)
            != Policy.followKeyboardCode)
    }

    @Test func explicitLanguageIsHonouredWithoutRetryCandidates() {
        let candidates = Policy.recordingLanguages(
            configuredLanguage: "bg-BG",
            for: Self.nemotron
        )
        #expect(candidates == ["bg-BG"])
    }

    @Test func autoDetectStaysAutoOnThePrimaryPass() {
        // Forcing a language the model is not hearing makes it translate rather
        // than mislabel, so auto must survive as the first element; the keyboard
        // languages ride along only as recovery candidates.
        let candidates = Policy.recordingLanguages(
            configuredLanguage: Policy.autoDetectCode,
            for: Self.nemotron
        )
        #expect(candidates.first == Policy.autoDetectCode)
    }
}

/// The validator only ever *triggers* a retry, so every ambiguous case has to
/// fail open — a wrong rejection costs a correct dictation.
struct TranscriptLanguageValidatorTests {

    @Test func acceptsTextInAnEnabledLanguage() {
        #expect(TranscriptLanguageValidator.accepts(
            "This is a normal English sentence about deployment scripts.",
            candidates: ["en-US", "bg-BG"]))
    }

    @Test func rejectsAConfidentlyForeignSentence() {
        #expect(!TranscriptLanguageValidator.accepts(
            "これは日本語の文章です。今日はとてもいい天気ですね。",
            candidates: ["en-US", "bg-BG"]))
    }

    @Test func failsOpenOnEmptyOrCandidateLessInput() {
        #expect(TranscriptLanguageValidator.accepts("", candidates: ["en-US"]))
        #expect(TranscriptLanguageValidator.accepts("   ", candidates: ["en-US"]))
        #expect(TranscriptLanguageValidator.accepts("anything", candidates: []))
    }

    @Test func keepsAmbiguousSingleWords() {
        // Names and brands must survive: they are the common short dictation.
        for word in ["Alice", "Microsoft", "OpenAI"] {
            #expect(TranscriptLanguageValidator.accepts(word, candidates: ["en-US", "bg-BG"]))
        }
    }

    @Test func allowsMixedLanguageText() {
        // Mixed script is legitimate; the rule is that a confident span must be
        // explainable by an enabled language, not that one script is used.
        #expect(TranscriptLanguageValidator.accepts(
            "OpenAI тест", candidates: ["en-US", "bg-BG"]))
    }
}

/// Script awareness exists for one failure the text validator cannot see:
/// handed the wrong language the model romanises instead of failing, and the
/// romanisation reads as perfectly valid text.
struct TranscriptScriptAwarenessTests {

    private typealias Validator = TranscriptLanguageValidator

    @Test func detectsScriptsPresentInText() {
        #expect(Validator.scripts(in: "Hello world") == ["Latin"])
        #expect(Validator.scripts(in: "Работи перфектно") == ["Cyrillic"])
        #expect(Validator.scripts(in: "OpenAI тест") == ["Latin", "Cyrillic"])
        // Punctuation and digits carry no script.
        #expect(Validator.scripts(in: "123 — !?").isEmpty)
    }

    @Test func mapsLanguagesToTheirScripts() {
        #expect(Validator.expectedScript(forBaseSubtag: "bg") == "Cyrillic")
        #expect(Validator.expectedScript(forBaseSubtag: "de") == "Latin")
        #expect(Validator.expectedScript(forBaseSubtag: "ja") == "Kana")
        // Unknown languages default to Latin, which can never add suspicion.
        #expect(Validator.expectedScript(forBaseSubtag: "xx") == "Latin")
    }

    @Test func flagsOnlyCandidatesWhoseScriptIsAbsent() {
        let mismatched = Validator.scriptMismatchedCandidates(
            ["bg-BG", "de-DE", "en-US"], primary: "Diktur na Bulgarski")
        // Only Bulgarian expects a script this all-Latin text never produced;
        // German and English are Latin, so they are not evidence of anything.
        #expect(mismatched == ["bg-BG"])

        let cyrillic = Validator.scriptMismatchedCandidates(
            ["bg-BG", "en-US"], primary: "Работи перфектно")
        #expect(cyrillic.isEmpty)
    }

    @Test func suspectsARomanisationThatTheValidatorAccepts() {
        // Romanised Bulgarian. Apple's recogniser reads it as Croatian (~0.78),
        // with Polish and Indonesian behind it.
        let text = "Diktur na Bulgarski"

        // With Bulgarian, German and English enabled the text validator already
        // rejects it outright — all of its probability mass sits outside the
        // candidate set — so recovery fires without needing the script check.
        #expect(!Validator.accepts(text, candidates: ["bg-BG", "de-DE", "en-US"]))

        // The hole opens when a keyboard the recogniser confuses Bulgarian with
        // is also enabled: now the romanisation is explained by an enabled
        // language and sails through. Only the missing Cyrillic gives it away.
        let confusable = ["hr-HR", "bg-BG"]
        #expect(Validator.accepts(text, candidates: confusable))
        #expect(Validator.scriptMismatchSuspected(text, candidates: confusable))
    }

    @Test func leavesConfidentLatinDictationAlone() {
        // A Cyrillic keyboard being installed must not drag every confident
        // English sentence into a retry.
        #expect(!Validator.scriptMismatchSuspected(
            "This is a normal English sentence about deployment scripts.",
            candidates: ["bg-BG", "en-US"]))
    }

    @Test func ordersMissingScriptsFirstAndEnglishLast() {
        let order = TranscriptLanguageRecovery.retryOrder(
            ["en-US", "de-DE", "bg-BG"], primary: "Diktur na Bulgarski")
        #expect(order == ["bg-BG", "de-DE", "en-US"])
    }
}

/// The recovery loop must never lose a dictation.
struct TranscriptLanguageRecoveryTests {

    @Test func keepsAValidPrimaryWithoutRetrying() async {
        var attempts = 0
        let result = await TranscriptLanguageRecovery.selectTranscript(
            primary: "This is a normal English sentence about deployment scripts.",
            validationCandidates: ["en-US", "bg-BG"],
            retryCandidates: ["bg-BG"]
        ) { _ in
            attempts += 1
            return "should not be used"
        }
        #expect(attempts == 0)
        #expect(result == "This is a normal English sentence about deployment scripts.")
    }

    @Test func preservesThePrimaryWhenEveryRetryFails() async {
        let primary = "これは日本語の文章です。今日はとてもいい天気ですね。"
        let result = await TranscriptLanguageRecovery.selectTranscript(
            primary: primary,
            validationCandidates: ["bg-BG", "en-US"],
            retryCandidates: ["bg-BG", "en-US"]
        ) { _ in throw CancellationError() }
        #expect(result == primary)
    }

    @Test func skipsEmptyRetriesAndContinuesToTheNextCandidate() async {
        var tried: [String] = []
        let result = await TranscriptLanguageRecovery.selectTranscript(
            primary: "これは日本語の文章です。今日はとてもいい天気ですね。",
            validationCandidates: ["bg-BG", "en-US"],
            retryCandidates: ["bg-BG", "en-US"]
        ) { language in
            tried.append(language)
            return language == "bg-BG"
                ? "   " : "This is a normal English sentence about deployment scripts."
        }
        // An empty first candidate must not stop the retained audio from
        // reaching a later language.
        #expect(tried == ["bg-BG", "en-US"])
        #expect(result == "This is a normal English sentence about deployment scripts.")
    }

    @Test func keepsASuspectPrimaryWhenNoProbeReadsClearlyBetter() async {
        // Suspected transliteration, but the probe is no better — the margin
        // stops genuine Latin dictation being over-converted.
        let primary = "Diktur na Bulgarski"
        let result = await TranscriptLanguageRecovery.selectTranscript(
            primary: primary,
            validationCandidates: ["en-US", "bg-BG"],
            retryCandidates: ["bg-BG"]
        ) { _ in "Diktur na Bulgarski" }
        #expect(result == primary)
    }

    @Test func probesEveryCandidateAndKeepsTheBestReading() async {
        var tried: [String] = []
        let result = await TranscriptLanguageRecovery.selectTranscript(
            primary: "これは日本語の文章です。今日はとてもいい天気ですね。",
            validationCandidates: ["bg-BG", "de-DE", "en-US"],
            retryCandidates: ["bg-BG", "de-DE", "en-US"]
        ) { language in
            tried.append(language)
            switch language {
            case "bg-BG": return "Работи"
            case "de-DE": return "Das ist ein ganz normaler deutscher Satz über Bereitstellung."
            default: return "This is a normal English sentence about deployment scripts."
            }
        }
        // All three are probed rather than stopping at the first that validates.
        #expect(tried.count == 3)
        #expect(tried.last == "en-US")
        #expect(!result.isEmpty)
    }

    @Test func recoversAnEmptyPrimary() async {
        let result = await TranscriptLanguageRecovery.selectTranscript(
            primary: "",
            validationCandidates: ["en-US"],
            retryCandidates: ["en-US"]
        ) { _ in "This is a normal English sentence about deployment scripts." }
        #expect(result == "This is a normal English sentence about deployment scripts.")
    }
}
