import Foundation
import Testing

@testable import VoiceInk

struct KeyboardLanguageModelOverrideTests {

    private typealias Override = KeyboardLanguageModelOverride

    private static let overrides = ["bg": "ggml-large-v3-turbo"]
    private static let follow = KeyboardLanguagePolicy.followKeyboardCode

    @Test func routesTheConfiguredKeyboardOnly() {
        #expect(
            Override.selectionKey(modeLanguage: Self.follow, activeKeyboard: "bg", overrides: Self.overrides)
                == "ggml-large-v3-turbo")
        #expect(
            Override.selectionKey(modeLanguage: Self.follow, activeKeyboard: "bg-BG", overrides: Self.overrides)
                == "ggml-large-v3-turbo")
        #expect(
            Override.selectionKey(modeLanguage: Self.follow, activeKeyboard: "de", overrides: Self.overrides)
                == nil)
        #expect(
            Override.selectionKey(modeLanguage: Self.follow, activeKeyboard: nil, overrides: Self.overrides)
                == nil)
    }

    @Test func leavesExplicitAndAutoDetectModesAlone() {
        for language in ["auto", "bg", nil] as [String?] {
            #expect(
                Override.selectionKey(modeLanguage: language, activeKeyboard: "bg", overrides: Self.overrides)
                    == nil)
        }
    }

    @Test func fallsBackToTheOtherModel() {
        let mode = "nemotron-multilingual-0.6b"
        // Whisper transcribed a Bulgarian dictation: Nemotron is the second opinion.
        #expect(
            Override.fallbackSelectionKey(
                primaryKey: "ggml-large-v3-turbo", modeKey: mode, overrides: Self.overrides) == mode)
        // Nemotron transcribed: Whisper is.
        #expect(
            Override.fallbackSelectionKey(primaryKey: mode, modeKey: mode, overrides: Self.overrides)
                == "ggml-large-v3-turbo")
        // No overrides, no fallback; an override pointing at the mode's own model is none either.
        #expect(Override.fallbackSelectionKey(primaryKey: mode, modeKey: mode, overrides: [:]) == nil)
        #expect(
            Override.fallbackSelectionKey(primaryKey: mode, modeKey: mode, overrides: ["bg": mode]) == nil)
    }

    @Test func readsOverridesFromDefaults() throws {
        let defaults = try #require(UserDefaults(suiteName: "KeyboardLanguageModelOverrideTests"))
        defer { defaults.removePersistentDomain(forName: "KeyboardLanguageModelOverrideTests") }

        #expect(Override.configuredOverrides(defaults: defaults).isEmpty)
        defaults.set(Self.overrides, forKey: Override.defaultsKey)
        #expect(Override.configuredOverrides(defaults: defaults) == Self.overrides)
    }
}
