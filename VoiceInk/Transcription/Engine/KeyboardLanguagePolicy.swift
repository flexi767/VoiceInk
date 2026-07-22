import Carbon.HIToolbox
import Foundation

/// Keyboard-conditioned language routing for this build's Nemotron workflow.
enum KeyboardLanguagePolicy {
    static let followKeyboardCode = "keyboard"
    static let nemotronModelName = "nemotron-multilingual-0.6b"

    static let selectableLanguages: [String: String] = [
        followKeyboardCode: "Follow Keyboard",
        "bg-BG": "Bulgarian",
        "de-DE": "German",
        "en-US": "English",
    ]

    private static let explicitLanguages = Set(selectableLanguages.keys.filter { $0 != followKeyboardCode })

    struct InputSourceLanguageInfo {
        let languages: [String]
        let localizedName: String?
    }

    static func applies(to model: any TranscriptionModel) -> Bool {
        model.provider == .fluidAudio && model.name == nemotronModelName
    }

    static func validLanguageOrFallback(_ language: String?) -> String {
        guard let language, explicitLanguages.contains(language) || language == followKeyboardCode else {
            return followKeyboardCode
        }
        return language
    }

    /// Freezes the ordered language candidates while the recording configuration
    /// is created. Explicit selections stay single-language; Follow Keyboard
    /// starts with the active source and then includes enabled supported sources.
    @MainActor
    static func recordingLanguages(
        configuredLanguage: String?,
        for model: any TranscriptionModel
    ) -> [String] {
        let validated = validLanguageOrFallback(configuredLanguage)
        guard applies(to: model), validated == followKeyboardCode else {
            return [validated]
        }

        let supported = allowedLanguages(for: model)
        guard !supported.isEmpty else { return [fallbackLanguage(in: supported)] }

        return orderedLanguages(
            active: currentInputSource(),
            enabled: enabledInputSources(),
            supported: supported
        )
    }

    static func orderedLanguages(
        active: InputSourceLanguageInfo?,
        enabled: [InputSourceLanguageInfo],
        supported: Set<String>
    ) -> [String] {
        var candidates: [String] = []
        var seenPrimaryLanguages: Set<String> = []
        func append(_ language: String?) {
            guard let language, let primary = primaryLanguageSubtag(language),
                seenPrimaryLanguages.insert(primary).inserted
            else { return }
            candidates.append(language)
        }

        append(active.flatMap { language(for: $0, supported: supported) })
        for source in enabled {
            append(language(for: source, supported: supported))
        }
        append(fallbackLanguage(in: supported))
        return candidates
    }

    /// Maps a BCP-47 identifier to a model locale without enumerating languages:
    /// exact canonical match first, then primary-language match.
    static func matchingSupportedLanguage(_ identifier: String, supported: Set<String>) -> String? {
        let canonical = canonicalLanguageIdentifier(identifier)
        guard !canonical.isEmpty else { return nil }

        if let exact = supported.first(where: {
            canonicalLanguageIdentifier($0).caseInsensitiveCompare(canonical) == .orderedSame
        }) {
            return exact
        }

        guard let primary = primaryLanguageSubtag(canonical) else { return nil }
        return supported.sorted().first { primaryLanguageSubtag($0) == primary }
    }

    static func language(for source: InputSourceLanguageInfo, supported: Set<String>) -> String? {
        for identifier in source.languages {
            if let match = matchingSupportedLanguage(identifier, supported: supported) {
                return match
            }
        }

        guard source.languages.isEmpty, let name = source.localizedName else { return nil }
        return languageFromLocalizedName(name, supported: supported)
    }

    static func primaryLanguageSubtag(_ identifier: String) -> String? {
        canonicalLanguageIdentifier(identifier)
            .split(separator: "-")
            .first
            .map { String($0).lowercased() }
    }

    @MainActor
    static func twoLetterDisplayCode(for language: String?) -> String {
        let resolvedLanguage = language ?? currentKeyboardLanguage()
        return primaryLanguageSubtag(resolvedLanguage)?.uppercased() ?? "--"
    }

    @MainActor
    static func currentKeyboardLanguage() -> String {
        let supported = explicitLanguages
        return currentInputSource().flatMap { language(for: $0, supported: supported) }
            ?? fallbackLanguage(in: supported)
    }

    private static func allowedLanguages(for model: any TranscriptionModel) -> Set<String> {
        Set(model.supportedLanguages.keys).intersection(explicitLanguages)
    }

    private static func fallbackLanguage(in supported: Set<String>) -> String {
        matchingSupportedLanguage("en", supported: supported) ?? supported.sorted().first ?? "en-US"
    }

    private static func canonicalLanguageIdentifier(_ identifier: String) -> String {
        Locale.canonicalLanguageIdentifier(from: identifier.replacingOccurrences(of: "_", with: "-"))
    }

    /// macOS metadata is authoritative. This generic name fallback compares the
    /// localized names of the model's supported language codes only when an
    /// input source exposes no BCP-47 metadata.
    private static func languageFromLocalizedName(_ name: String, supported: Set<String>) -> String? {
        let normalizedName = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        for identifier in supported.sorted() {
            guard let primary = primaryLanguageSubtag(identifier) else { continue }
            let localizedNames = [
                Locale.current.localizedString(forLanguageCode: primary),
                Locale(identifier: identifier).localizedString(forLanguageCode: primary),
                Locale(identifier: "en").localizedString(forLanguageCode: primary),
            ]
            for localized in localizedNames.compactMap({ $0 }) {
                let normalized = localized.folding(
                    options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                if normalizedName.contains(normalized) { return identifier }
            }
        }
        return nil
    }

    @MainActor
    private static func currentInputSource() -> InputSourceLanguageInfo? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return inputSourceInfo(source)
    }

    @MainActor
    private static func enabledInputSources() -> [InputSourceLanguageInfo] {
        guard let sourceList = TISCreateInputSourceList(nil, false)?.takeRetainedValue() else { return [] }
        let sources = sourceList as NSArray
        return sources.compactMap { value in
            inputSourceInfo(value as! TISInputSource)
        }
    }

    private static func inputSourceInfo(_ source: TISInputSource) -> InputSourceLanguageInfo {
        InputSourceLanguageInfo(
            languages: stringArrayProperty(kTISPropertyInputSourceLanguages, from: source),
            localizedName: stringProperty(kTISPropertyLocalizedName, from: source)
        )
    }

    private static func stringProperty(_ property: CFString, from source: TISInputSource) -> String? {
        guard let value = TISGetInputSourceProperty(source, property) else { return nil }
        return Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
    }

    private static func stringArrayProperty(_ property: CFString, from source: TISInputSource) -> [String] {
        guard let value = TISGetInputSourceProperty(source, property) else { return [] }
        let values = Unmanaged<CFArray>.fromOpaque(value).takeUnretainedValue() as NSArray
        return values.compactMap { $0 as? String }
    }
}
