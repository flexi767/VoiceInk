import Carbon.HIToolbox
import Foundation

/// Keyboard-conditioned language routing for this build's Nemotron workflow.
enum KeyboardLanguagePolicy {
    static let followKeyboardCode = "keyboard"
    static let installedKeyboardLanguagesLabel = String(localized: "Use only installed keyboard languages")
    static let nemotronModelName = "nemotron-multilingual-0.6b"

    struct InputSourceLanguageInfo {
        let languages: [String]
        let localizedName: String?
    }

    static func applies(to model: any TranscriptionModel) -> Bool {
        model.provider == .fluidAudio && model.name == nemotronModelName
    }

    static func selectableLanguages(for model: any TranscriptionModel) -> [String: String] {
        selectableLanguages(
            active: currentInputSource(),
            enabled: enabledInputSources(),
            supportedLanguages: model.supportedLanguages
        )
    }

    static func selectableLanguages(
        active: InputSourceLanguageInfo?,
        enabled: [InputSourceLanguageInfo],
        supportedLanguages: [String: String]
    ) -> [String: String] {
        let supported = supportedLanguageCodes(from: supportedLanguages)
        let installed = orderedLanguages(active: active, enabled: enabled, supported: supported)
        var result = [followKeyboardCode: installedKeyboardLanguagesLabel]
        for identifier in installed {
            result[identifier] = supportedLanguages[identifier]
                ?? localizedDisplayName(for: identifier)
                ?? identifier
        }
        return result
    }

    static func validLanguageOrFallback(
        _ language: String?,
        for model: any TranscriptionModel
    ) -> String {
        let available = selectableLanguages(for: model)
        return validLanguageOrFallback(language, availableLanguages: available)
    }

    static func validLanguageOrFallback(
        _ language: String?,
        availableLanguages: [String: String]
    ) -> String {
        guard let language, availableLanguages[language] != nil else {
            return followKeyboardCode
        }
        return language
    }

    /// Freezes the ordered language candidates while the recording configuration
    /// is created. Explicit selections stay single-language; keyboard routing
    /// starts with the active source and then includes enabled supported sources.
    @MainActor
    static func recordingLanguages(
        configuredLanguage: String?,
        for model: any TranscriptionModel
    ) -> [String] {
        let validated = validLanguageOrFallback(configuredLanguage, for: model)
        guard applies(to: model), validated == followKeyboardCode else {
            return [validated]
        }

        let supported = allowedLanguages(for: model)
        guard !supported.isEmpty else { return [fallbackLanguage(in: supported)] }

        let candidates = orderedLanguages(
            active: currentInputSource(),
            enabled: enabledInputSources(),
            supported: supported
        )
        return candidates.isEmpty ? [fallbackLanguage(in: supported)] : candidates
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

    static func twoLetterDisplayCode(for language: String?) -> String {
        primaryLanguageSubtag(language ?? "")?.uppercased() ?? "--"
    }

    private static func allowedLanguages(for model: any TranscriptionModel) -> Set<String> {
        supportedLanguageCodes(from: model.supportedLanguages)
    }

    private static func supportedLanguageCodes(from languages: [String: String]) -> Set<String> {
        Set(languages.keys.filter {
            let primary = primaryLanguageSubtag($0)
            return primary != nil && primary != "auto"
        })
    }

    private static func fallbackLanguage(in supported: Set<String>) -> String {
        matchingSupportedLanguage("en", supported: supported) ?? supported.sorted().first ?? "en-US"
    }

    private static func canonicalLanguageIdentifier(_ identifier: String) -> String {
        Locale.canonicalLanguageIdentifier(from: identifier.replacingOccurrences(of: "_", with: "-"))
    }

    private static func localizedDisplayName(for identifier: String) -> String? {
        let canonical = canonicalLanguageIdentifier(identifier)
        return Locale.current.localizedString(forIdentifier: canonical)
            ?? primaryLanguageSubtag(canonical).flatMap {
                Locale.current.localizedString(forLanguageCode: $0)
            }
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

    private static func currentInputSource() -> InputSourceLanguageInfo? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return inputSourceInfo(source)
    }

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
