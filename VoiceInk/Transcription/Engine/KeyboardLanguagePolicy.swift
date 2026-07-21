import Carbon.HIToolbox
import Foundation

/// Restricts the keyboard-conditioned Nemotron workflow to the three languages
/// used by this VoiceInk build.
enum KeyboardLanguagePolicy {
    static let followKeyboardCode = "keyboard"
    static let nemotronModelName = "nemotron-multilingual-0.6b"

    static let selectableLanguages: [String: String] = [
        followKeyboardCode: "Follow Keyboard",
        "bg-BG": "Bulgarian",
        "de-DE": "German",
        "en-US": "English",
    ]

    private static let explicitLanguages: Set<String> = ["bg-BG", "de-DE", "en-US"]

    static func applies(to model: any TranscriptionModel) -> Bool {
        model.provider == .fluidAudio && model.name == nemotronModelName
    }

    static func validLanguageOrFallback(_ language: String?) -> String {
        guard let language, explicitLanguages.contains(language) || language == followKeyboardCode else {
            return followKeyboardCode
        }
        return language
    }

    static func resolvedLanguage(_ configuredLanguage: String?) async -> String {
        let validated = validLanguageOrFallback(configuredLanguage)
        guard validated == followKeyboardCode else { return validated }

        return await MainActor.run {
            currentKeyboardLanguage()
        }
    }

    /// Resolves "Follow Keyboard" while the recording configuration is created,
    /// so the chosen language remains stable for the full recording session.
    @MainActor
    static func requestLanguage(
        configuredLanguage: String?,
        for model: any TranscriptionModel
    ) -> String {
        let validated = validLanguageOrFallback(configuredLanguage)
        guard applies(to: model), validated == followKeyboardCode else {
            return validated
        }

        return currentKeyboardLanguage()
    }

    static func language(inputSourceID: String?, localizedName: String?) -> String {
        let descriptor = [inputSourceID, localizedName]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")

        if descriptor.contains("bulgarian") || descriptor.contains("българ") {
            return "bg-BG"
        }

        if descriptor.contains("german") || descriptor.contains("deutsch") {
            return "de-DE"
        }

        return "en-US"
    }

    @MainActor
    static func twoLetterDisplayCode(for language: String?) -> String {
        let resolvedLanguage = language ?? currentKeyboardLanguage()
        let normalizedLanguage = resolvedLanguage.lowercased()

        if normalizedLanguage.hasPrefix("bg") { return "BG" }
        if normalizedLanguage.hasPrefix("de") { return "DE" }
        return "EN"
    }

    @MainActor
    static func currentKeyboardLanguage() -> String {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return "en-US"
        }

        return language(
            inputSourceID: stringProperty(kTISPropertyInputSourceID, from: source),
            localizedName: stringProperty(kTISPropertyLocalizedName, from: source)
        )
    }

    private static func stringProperty(_ property: CFString, from source: TISInputSource) -> String? {
        guard let value = TISGetInputSourceProperty(source, property) else { return nil }
        return Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
    }
}
