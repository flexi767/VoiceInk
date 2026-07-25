import Carbon.HIToolbox
import Foundation

/// Keyboard-conditioned language routing.
///
/// The macOS keyboard layout in effect when a recording starts is a strong
/// signal for the language about to be spoken — far stronger than a model's own
/// guess on a one-second clip. When the transcription language is set to
/// `follow_keyboard`, that layout is frozen for the whole recording and the
/// user's other enabled layouts are kept as ordered fallback candidates.
///
/// Three rules, each of which cost a regression to learn:
///
/// 1. **Every** Text Input Source call runs on the main dispatch queue.
///    `TISCreateInputSourceList` has always asserted it; as of macOS 26
///    `TISGetInputSourceProperty` does too, by way of `isValidateInputSourceRef`,
///    and it aborts the process rather than returning nil. The assert only fires
///    while the input-source list cache is cold (just after login), so an
///    off-main read can work for a whole session and then kill the app on the
///    next boot. `readInputSources()` is the single choke point.
///
/// 2. A keyboard-resolved language only ever reaches a model whose language
///    parameter is a genuine decoding hint. For the Parakeet family FluidAudio's
///    `Language` is a `TokenLanguageFilter` — a Unicode *script* filter over the
///    joint network's argmax — so forcing one suppresses every token in the
///    wrong script, the leading word included. `supportsFollowKeyboard(for:)`
///    is what keeps that from happening.
///
/// 3. Auto-detect is never silently replaced by a guess. A model left on
///    "auto" stays on auto for the primary pass; the keyboard languages ride
///    along only as recovery candidates. Forcing a language the model is not
///    hearing makes whisper.cpp *translate* into it rather than mislabel.
enum KeyboardLanguagePolicy {

    /// Sentinel `selectedLanguage` meaning "use whichever keyboard layout is
    /// active when recording starts". Never handed to a model.
    static let followKeyboardCode = "follow_keyboard"

    /// Sentinel meaning "let the model detect the language". Never a spoken
    /// language, and never a recovery candidate.
    static let autoDetectCode = "auto"

    /// Menu label for `followKeyboardCode`. Names the constraint rather than the
    /// mechanism: the choice is restricted to the languages of the keyboards the
    /// user has installed, never opened up to unrestricted detection.
    static var installedKeyboardLanguagesLabel: String {
        String(localized: "Installed keyboard languages only")
    }

    /// A keyboard layout's advertised languages, plus its display name for the
    /// rare layout that carries no BCP-47 metadata at all.
    struct InputSource {
        let languages: [String]
        let localizedName: String?
    }

    // MARK: - Capability

    /// Whether this model's language parameter is a real decoding hint, and so
    /// safe to drive from the keyboard.
    ///
    /// Nemotron takes a prompt id that conditions the encoder; whisper.cpp takes
    /// a decoder language token. Parakeet takes a *script filter* — see rule 2.
    static func supportsFollowKeyboard(for model: any TranscriptionModel) -> Bool {
        guard model.isMultilingualModel else { return false }

        switch model.provider {
        case .whisper:
            return true
        case .fluidAudio:
            return FluidAudioModelManager.isNemotronModel(named: model.name)
        default:
            return false
        }
    }

    /// The model's own language menu, with `follow_keyboard` prepended when the
    /// model supports it *and* at least one installed layout maps onto a
    /// language it advertises. Offering a sentinel that resolves to nothing
    /// would just be a broken menu entry.
    static func selectableLanguages(for model: any TranscriptionModel) -> [String: String] {
        var languages = model.supportedLanguages
        guard supportsFollowKeyboard(for: model),
            !keyboardLanguages(supportedBy: languages).isEmpty
        else { return languages }

        languages[followKeyboardCode] = installedKeyboardLanguagesLabel
        return languages
    }

    // MARK: - Per-recording resolution

    /// Freezes the ordered languages for one recording. The first element is the
    /// language the primary pass runs with; the rest are recovery candidates, in
    /// **keyboard order** — the active layout first, then the other enabled ones.
    ///
    /// Recovery reorders them for its own purposes, and needs the keyboard order
    /// to do it: which reordering is right depends on why recovery fired, which
    /// is not known here.
    ///
    /// Never returns `follow_keyboard`, and never returns an empty array.
    static func recordingLanguages(
        configuredLanguage: String?,
        for model: any TranscriptionModel
    ) -> [String] {
        var configured = configuredLanguage ?? autoDetectCode
        let supported = model.supportedLanguages

        // Models whose language is not a real hint pass straight through: their
        // configured value was already validated against their own dictionary.
        // A stale sentinel — selected under another model, then switched — must
        // still never leave this function.
        guard supportsFollowKeyboard(for: model) else {
            guard configured == followKeyboardCode else { return [configured] }
            return [supported[autoDetectCode] != nil ? autoDetectCode : configured]
        }

        let keyboard = keyboardLanguages(supportedBy: supported)

        if configured == followKeyboardCode {
            // No layout maps onto a supported language — fall back to detection
            // rather than inventing one.
            guard !keyboard.isEmpty else {
                return [supported[autoDetectCode] != nil ? autoDetectCode : configured]
            }
            return keyboard
        }

        // An explicit choice is honoured exactly, with no cross-language retry.
        guard configured == autoDetectCode else { return [configured] }

        // Rule 3: auto stays auto on the primary pass.
        return [autoDetectCode] + keyboard
    }

    /// Resolves a possibly-sentinel language into something a model can accept.
    /// A defensive net for entry points that read `SelectedLanguage` directly
    /// (file transcription, for one) instead of going through the recording
    /// snapshot.
    static func resolvedLanguage(
        _ language: String?,
        for model: any TranscriptionModel
    ) -> String {
        let resolved =
            language == followKeyboardCode
            ? recordingLanguages(configuredLanguage: language, for: model).first
            : language

        // `selectableLanguages` lists the sentinel as a valid menu entry, so
        // `validLanguageOrFallback` would happily pass it through. Strip it
        // first: this function's contract is that a model can accept the result.
        let usable = resolved == followKeyboardCode ? nil : resolved
        return TranscriptionLanguageSupport.validLanguageOrFallback(usable, for: model)
    }

    // MARK: - Keyboard layouts

    /// Installed keyboard languages mapped onto the model's own codes: the
    /// active layout first, then the other enabled layouts, de-duplicated by
    /// base subtag.
    static func keyboardLanguages(supportedBy supported: [String: String]) -> [String] {
        let codes = Set(
            supported.keys.filter { $0 != autoDetectCode && $0 != followKeyboardCode })
        guard !codes.isEmpty else { return [] }

        let sources = readInputSources()
        return orderedLanguages(active: sources.active, enabled: sources.enabled, supported: codes)
    }

    /// The active layout's two-letter code for the recorder badge, e.g. `BG`.
    static func activeKeyboardDisplayCode() -> String? {
        let sources = readInputSources()
        guard let identifier = sources.active?.languages.first else { return nil }
        return baseSubtag(identifier)?.uppercased()
    }

    static func twoLetterDisplayCode(for language: String?) -> String {
        guard let language, language != autoDetectCode, language != followKeyboardCode else {
            return activeKeyboardDisplayCode() ?? "--"
        }
        return baseSubtag(language)?.uppercased() ?? "--"
    }

    static func orderedLanguages(
        active: InputSource?,
        enabled: [InputSource],
        supported: Set<String>
    ) -> [String] {
        var ordered: [String] = []
        var seen: Set<String> = []

        func append(_ language: String?) {
            guard let language, let base = baseSubtag(language), seen.insert(base).inserted else {
                return
            }
            ordered.append(language)
        }

        append(active.flatMap { language(for: $0, supported: supported) })
        for source in enabled {
            append(language(for: source, supported: supported))
        }
        return ordered
    }

    static func language(for source: InputSource, supported: Set<String>) -> String? {
        for identifier in source.languages {
            if let match = matchingSupportedLanguage(identifier, supported: supported) {
                return match
            }
        }

        // macOS metadata is authoritative; the name is only consulted when a
        // layout advertises no languages at all.
        guard source.languages.isEmpty, let name = source.localizedName else { return nil }
        return languageFromLocalizedName(name, supported: supported)
    }

    /// Maps a BCP-47 identifier onto a model's advertised code without
    /// enumerating languages: exact canonical match first, then base subtag.
    ///
    /// The base-subtag step is what makes a `bg` keyboard reach a model that
    /// advertises `bg-BG`; string equality alone silently skips every candidate.
    static func matchingSupportedLanguage(_ identifier: String, supported: Set<String>) -> String? {
        let target = canonical(identifier)
        guard !target.isEmpty else { return nil }

        if let exact = supported.first(where: {
            canonical($0).caseInsensitiveCompare(target) == .orderedSame
        }) {
            return exact
        }

        guard let base = baseSubtag(target) else { return nil }
        return supported.sorted().first { baseSubtag($0) == base }
    }

    static func baseSubtag(_ identifier: String) -> String? {
        canonical(identifier).split(separator: "-").first.map { $0.lowercased() }
    }

    // MARK: - Carbon Text Input Sources

    private struct Snapshot {
        var active: InputSource?
        var enabled: [InputSource]
    }

    private static let cacheLock = NSLock()
    private static var cachedSnapshot: Snapshot?

    /// The one place TIS is touched.
    ///
    /// Reads happen on the main thread and are cached; a caller already off the
    /// main thread gets the cached value rather than hopping. `validLanguageOrFallback`
    /// is reachable from the transcription actors, and a `DispatchQueue.main.sync`
    /// from there would deadlock against a main thread awaiting that same
    /// transcription. The cache is refreshed on every main-thread call, which
    /// includes the recording-start snapshot — the only moment the value has to
    /// be current. A cold cache off the main thread reports no keyboards, which
    /// degrades to auto-detect rather than to a wrong language.
    private static func readInputSources() -> (active: InputSource?, enabled: [InputSource]) {
        guard Thread.isMainThread else {
            cacheLock.lock()
            defer { cacheLock.unlock() }
            guard let cached = cachedSnapshot else { return (nil, []) }
            return (cached.active, cached.enabled)
        }

        let snapshot = readInputSourcesOnMainThread()
        cacheLock.lock()
        cachedSnapshot = Snapshot(active: snapshot.active, enabled: snapshot.enabled)
        cacheLock.unlock()
        return snapshot
    }

    /// See rule 1: every TIS call here, property reads included, requires the
    /// main queue.
    private static func readInputSourcesOnMainThread() -> (
        active: InputSource?, enabled: [InputSource]
    ) {
        var active: InputSource?
        if let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() {
            active = info(for: source)
        }

        // `includeAllInstalled = false` — layouts the user has not enabled must
        // not become candidates.
        var enabled: [InputSource] = []
        if let list = TISCreateInputSourceList(nil, false)?.takeRetainedValue() {
            enabled = (list as NSArray).map { info(for: $0 as! TISInputSource) }
        }

        return (active, enabled)
    }

    private static func info(for source: TISInputSource) -> InputSource {
        InputSource(
            languages: stringArrayProperty(kTISPropertyInputSourceLanguages, from: source),
            localizedName: stringProperty(kTISPropertyLocalizedName, from: source)
        )
    }

    private static func stringProperty(_ property: CFString, from source: TISInputSource) -> String? {
        guard let value = TISGetInputSourceProperty(source, property) else { return nil }
        return Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
    }

    private static func stringArrayProperty(
        _ property: CFString, from source: TISInputSource
    ) -> [String] {
        guard let value = TISGetInputSourceProperty(source, property) else { return [] }
        return (Unmanaged<CFArray>.fromOpaque(value).takeUnretainedValue() as NSArray)
            .compactMap { $0 as? String }
    }

    // MARK: - Locale helpers

    private static func canonical(_ identifier: String) -> String {
        Locale.canonicalLanguageIdentifier(
            from: identifier.replacingOccurrences(of: "_", with: "-"))
    }

    /// Compares a layout's localized name against the localized names of the
    /// model's own language codes. Only reached when macOS supplies no BCP-47
    /// metadata, so no language list is hardcoded here either.
    private static func languageFromLocalizedName(_ name: String, supported: Set<String>) -> String? {
        let normalizedName = name.folding(
            options: [.caseInsensitive, .diacriticInsensitive], locale: .current)

        for identifier in supported.sorted() {
            guard let base = baseSubtag(identifier) else { continue }
            let candidates = [
                Locale.current.localizedString(forLanguageCode: base),
                Locale(identifier: "en").localizedString(forLanguageCode: base),
            ].compactMap { $0 }

            for candidate in candidates {
                let normalized = candidate.folding(
                    options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                if normalizedName.contains(normalized) { return identifier }
            }
        }
        return nil
    }
}
