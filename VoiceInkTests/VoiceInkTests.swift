//
//  VoiceInkTests.swift
//  VoiceInkTests
//

import Testing
@testable import VoiceInk

struct VoiceInkTests {
    private let supported: Set<String> = ["bg-BG", "de-DE", "en-US", "fr-FR", "sr-Latn", "zh-Hant"]

    @Test func mapsArbitraryBCP47MetadataToModelLocales() {
        #expect(KeyboardLanguagePolicy.matchingSupportedLanguage("fr-FR", supported: supported) == "fr-FR")
        #expect(KeyboardLanguagePolicy.matchingSupportedLanguage("sr-Latn", supported: supported) == "sr-Latn")
        #expect(KeyboardLanguagePolicy.matchingSupportedLanguage("zh-Hant", supported: supported) == "zh-Hant")
        #expect(KeyboardLanguagePolicy.matchingSupportedLanguage("de", supported: supported) == "de-DE")
        #expect(KeyboardLanguagePolicy.matchingSupportedLanguage("bg_BG", supported: supported) == "bg-BG")
        #expect(KeyboardLanguagePolicy.matchingSupportedLanguage("es-419", supported: supported) == nil)
    }

    @Test func metadataWinsAndLocalizedNameIsOnlyAFallback() {
        let metadataSource = KeyboardLanguagePolicy.InputSourceLanguageInfo(
            languages: ["fr"], localizedName: "German")
        #expect(KeyboardLanguagePolicy.language(for: metadataSource, supported: supported) == "fr-FR")

        let nameOnlySource = KeyboardLanguagePolicy.InputSourceLanguageInfo(
            languages: [], localizedName: "German – Third Party")
        #expect(KeyboardLanguagePolicy.language(for: nameOnlySource, supported: supported) == "de-DE")
    }

    @Test func recordingCandidatesKeepActiveFirstAndDeduplicatePrimaryLanguage() {
        let active = KeyboardLanguagePolicy.InputSourceLanguageInfo(languages: ["de"], localizedName: nil)
        let enabled = [
            KeyboardLanguagePolicy.InputSourceLanguageInfo(languages: ["en-GB"], localizedName: nil),
            KeyboardLanguagePolicy.InputSourceLanguageInfo(languages: ["bg"], localizedName: nil),
            KeyboardLanguagePolicy.InputSourceLanguageInfo(languages: ["de-DE"], localizedName: nil),
            KeyboardLanguagePolicy.InputSourceLanguageInfo(languages: ["fr"], localizedName: nil),
        ]

        #expect(
            KeyboardLanguagePolicy.orderedLanguages(
                active: active,
                enabled: enabled,
                supported: ["bg-BG", "de-DE", "en-US"]
            ) == ["de-DE", "en-US", "bg-BG"]
        )
    }

    @Test func selectorUsesOnlyInstalledModelSupportedKeyboardLanguages() {
        let active = KeyboardLanguagePolicy.InputSourceLanguageInfo(languages: ["fr-FR"], localizedName: nil)
        let enabled = [
            KeyboardLanguagePolicy.InputSourceLanguageInfo(languages: ["sr-Latn"], localizedName: nil),
            KeyboardLanguagePolicy.InputSourceLanguageInfo(languages: ["zh-Hant"], localizedName: nil),
            KeyboardLanguagePolicy.InputSourceLanguageInfo(languages: ["es-ES"], localizedName: nil),
        ]
        let selectable = KeyboardLanguagePolicy.selectableLanguages(
            active: active,
            enabled: enabled,
            supportedLanguages: [
                "auto": "Auto-detect",
                "en-US": "English",
                "fr-FR": "French",
                "sr-Latn": "Serbian (Latin)",
                "zh-Hant": "Traditional Chinese",
            ]
        )

        #expect(Set(selectable.keys) == ["keyboard", "fr-FR", "sr-Latn", "zh-Hant"])
        #expect(selectable["en-US"] == nil)
        #expect(selectable["es-ES"] == nil)
        #expect(KeyboardLanguagePolicy.validLanguageOrFallback(
            "sr-Latn", availableLanguages: selectable) == "sr-Latn")
        #expect(KeyboardLanguagePolicy.validLanguageOrFallback(
            "en-US", availableLanguages: selectable) == "keyboard")
    }

    @Test @MainActor func formatsGenericTwoLetterDisplayCodes() {
        #expect(KeyboardLanguagePolicy.twoLetterDisplayCode(for: "en-US") == "EN")
        #expect(KeyboardLanguagePolicy.twoLetterDisplayCode(for: "de-DE") == "DE")
        #expect(KeyboardLanguagePolicy.twoLetterDisplayCode(for: "bg-BG") == "BG")
        #expect(KeyboardLanguagePolicy.twoLetterDisplayCode(for: "fr-FR") == "FR")
    }

    @Test func catchesSavedWrongLanguageRegressions() {
        let candidates = ["de-DE", "en-US", "bg-BG"]
        #expect(!TranscriptLanguageValidator.accepts(
            "Št je svârsza spokojna.", expectedLanguage: "de-DE", candidates: candidates))
        #expect(!TranscriptLanguageValidator.accepts(
            "Ю шуднт хит ютуб, райт.", expectedLanguage: "en-US", candidates: candidates))
        #expect(!TranscriptLanguageValidator.accepts(
            "Моля ти протиміснимка.", expectedLanguage: "bg-BG", candidates: candidates))
        #expect(!TranscriptLanguageValidator.accepts(
            "Сега срещу вороно Богорский", expectedLanguage: "bg-BG", candidates: candidates))
    }

    @Test func allowsSupportedMixedLanguageAndAmbiguousBrands() {
        let candidates = ["bg-BG", "en-US", "de-DE"]
        #expect(TranscriptLanguageValidator.accepts(
            "OpenAI тест", expectedLanguage: "bg-BG", candidates: candidates))
        #expect(TranscriptLanguageValidator.accepts(
            "Microsoft", expectedLanguage: "en-US", candidates: candidates))
        #expect(TranscriptLanguageValidator.accepts(
            "Alice", expectedLanguage: "en-US", candidates: candidates))
    }

    @Test func unsupportedOneWordProbabilityTriggersRecovery() {
        let candidates = ["de-DE", "en-US", "bg-BG"]
        let probability = TranscriptLanguageValidator.outsideCandidateProbability(
            for: "Está.", candidates: candidates)
        #expect(probability != nil)
        #expect(probability! >= 0.85)
        #expect(!TranscriptLanguageValidator.accepts(
            "Está.", expectedLanguage: "de-DE", candidates: candidates))
    }

    @Test func recoveryUsesFirstValidatedForcedResultAndFailsOpen() async {
        let candidates = ["de-DE", "en-US", "bg-BG"]
        var attempted: [String] = []
        let recovered = await TranscriptLanguageRecovery.selectTranscript(
            primary: "Está.", candidates: candidates
        ) { language in
            attempted.append(language)
            switch language {
            case "de-DE": return ""
            case "en-US": return "This is the recovered English result."
            default: return "Това е възстановеният български резултат."
            }
        }
        #expect(recovered == "This is the recovered English result.")
        #expect(attempted == ["de-DE", "en-US"])

        let original = await TranscriptLanguageRecovery.selectTranscript(
            primary: "Está.", candidates: candidates
        ) { _ in "" }
        #expect(original == "Está.")
    }
}
