import Foundation

/// Per-keyboard-language transcription model, for a language the mode's own
/// model reads poorly.
///
/// Nemotron streams English and German well but garbles Bulgarian, which
/// Whisper large-v3-turbo reads far better — at the cost of loading 1.6 GB per
/// dictation and giving up streaming. Routing only the Bulgarian layout to
/// Whisper keeps that cost off every other dictation.
///
/// Stored as `[base subtag: model selection key]` under `defaultsKey`. There is
/// no settings UI yet:
///
///     defaults write com.prakashjoshipax.VoiceInk KeyboardLanguageModelOverrides \
///         -dict bg ggml-large-v3-turbo
///
/// The two models also stand in for each other when a transcript reads as
/// nonsense — see `TranscriptNonsenseDetector`.
enum KeyboardLanguageModelOverride {

    static let defaultsKey = "KeyboardLanguageModelOverrides"

    static func configuredOverrides(defaults: UserDefaults = .standard) -> [String: String] {
        (defaults.dictionary(forKey: defaultsKey) as? [String: String]) ?? [:]
    }

    /// The selection key to transcribe with instead of the mode's model, or nil
    /// to keep the mode's model.
    ///
    /// Only a `follow_keyboard` mode is routed: an explicit language or
    /// auto-detect means the user did not ask the keyboard to decide.
    static func selectionKey(
        modeLanguage: String?,
        activeKeyboard: String?,
        overrides: [String: String]
    ) -> String? {
        guard modeLanguage == KeyboardLanguagePolicy.followKeyboardCode,
            let base = activeKeyboard.flatMap(KeyboardLanguagePolicy.baseSubtag)
        else { return nil }
        return overrides[base]
    }

    /// The model to re-run a nonsense transcript with: the mode's own model when
    /// an override transcribed it, otherwise the first override model.
    static func fallbackSelectionKey(
        primaryKey: String,
        modeKey: String,
        overrides: [String: String]
    ) -> String? {
        if primaryKey != modeKey { return modeKey }
        return overrides.keys.sorted().compactMap { overrides[$0] }.first { $0 != modeKey }
    }
}
