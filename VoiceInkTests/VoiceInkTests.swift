//
//  VoiceInkTests.swift
//  VoiceInkTests
//
//  Created by Prakash Joshi on 15/10/2024.
//

import Testing
@testable import VoiceInk

struct VoiceInkTests {

    @Test func keyboardLanguagePolicyMapsSupportedLayouts() {
        #expect(
            KeyboardLanguagePolicy.language(
                inputSourceID: "com.apple.keylayout.ABC",
                localizedName: "ABC"
            ) == "en-US"
        )
        #expect(
            KeyboardLanguagePolicy.language(
                inputSourceID: "com.apple.keylayout.German",
                localizedName: "German"
            ) == "de-DE"
        )
        #expect(
            KeyboardLanguagePolicy.language(
                inputSourceID: "com.apple.keylayout.Bulgarian-Phonetic",
                localizedName: "Bulgarian – Phonetic"
            ) == "bg-BG"
        )
    }

    @Test func keyboardLanguagePolicyRejectsUnsupportedSelections() {
        #expect(KeyboardLanguagePolicy.validLanguageOrFallback("fr-FR") == "keyboard")
        #expect(KeyboardLanguagePolicy.validLanguageOrFallback("auto") == "keyboard")
        #expect(KeyboardLanguagePolicy.validLanguageOrFallback("de-DE") == "de-DE")
    }

    @Test func keyboardLanguagePolicyFallsBackToEnglishForUnknownLayouts() {
        #expect(
            KeyboardLanguagePolicy.language(
                inputSourceID: "com.example.unknown",
                localizedName: "Unknown"
            ) == "en-US"
        )
    }

    @Test @MainActor func keyboardLanguagePolicyFormatsTwoLetterDisplayCodes() {
        #expect(KeyboardLanguagePolicy.twoLetterDisplayCode(for: "en-US") == "EN")
        #expect(KeyboardLanguagePolicy.twoLetterDisplayCode(for: "de-DE") == "DE")
        #expect(KeyboardLanguagePolicy.twoLetterDisplayCode(for: "bg-BG") == "BG")
    }

}
