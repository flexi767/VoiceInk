import Foundation

struct TranscriptionRuntimeConfiguration {
    let mode: ModeConfig
    let model: any TranscriptionModel
    let language: String
    /// Languages frozen for this recording, in the order they should be tried:
    /// `language` first, then wrong-language recovery candidates. Holds a single
    /// element whenever recovery does not apply.
    let languageCandidates: [String]
    let isRealtimeEnabled: Bool

    /// Candidates to retry the retained audio with when the primary transcript
    /// lands outside the user's keyboard languages.
    var recoveryCandidates: [String] {
        Array(languageCandidates.dropFirst())
    }

    var metadata: (name: String?, emoji: String?) {
        guard mode.isEnabled else {
            return (nil, nil)
        }
        return (mode.name, mode.icon.value)
    }

    var requestContext: TranscriptionRequestContext {
        TranscriptionRequestContext(
            language: language,
            prompt: model.provider == .whisper ? WhisperPrompt.resolvedPrompt(for: language) : nil
        )
    }
}

struct TranscriptionFormattingConfiguration {
    let mode: ModeConfig?
    let isTextFormattingEnabled: Bool
}

struct EnhancementRuntimeConfiguration {
    let mode: ModeConfig?
    let isEnabled: Bool
    let prompt: CustomPrompt?
    let provider: AIProvider?
    let modelName: String?
    let useClipboardContext: Bool
    let useSelectedTextContext: Bool
    let useScreenCaptureContext: Bool

    func replacingPrompt(_ prompt: CustomPrompt) -> EnhancementRuntimeConfiguration {
        EnhancementRuntimeConfiguration(
            mode: mode,
            isEnabled: true,
            prompt: prompt,
            provider: provider,
            modelName: modelName,
            useClipboardContext: useClipboardContext,
            useSelectedTextContext: useSelectedTextContext,
            useScreenCaptureContext: useScreenCaptureContext
        )
    }
}

struct OutputRuntimeConfiguration {
    let mode: ModeConfig?
    let outputMode: ModeOutputMode
    let customCommand: ModeCustomCommand?
}

enum ModeTranscriptionModelResolution {
    case noMode
    case noSelection(mode: ModeConfig)
    case modelNotFound(mode: ModeConfig)
    case unavailable(mode: ModeConfig, model: any TranscriptionModel)
    case available(mode: ModeConfig, model: any TranscriptionModel)
}

@MainActor
enum ModeRuntimeResolver {
    static func transcriptionModelResolution(
        mode: ModeConfig? = nil,
        transcriptionModelManager: TranscriptionModelManager
    ) -> ModeTranscriptionModelResolution {
        guard let mode = mode ?? ModeManager.shared.currentEffectiveConfiguration else {
            return .noMode
        }

        guard let modelName = mode.selectedTranscriptionModelName,
            !modelName.isEmpty
        else {
            return .noSelection(mode: mode)
        }

        guard
            let model = TranscriptionModelRegistry.model(
                forSelectionKey: modelName,
                in: transcriptionModelManager.allAvailableModels
            )
        else {
            return .modelNotFound(mode: mode)
        }

        guard transcriptionModelManager.usableModels.contains(where: {
            $0.selectionKey == model.selectionKey
        }) else {
            return .unavailable(mode: mode, model: model)
        }

        return .available(mode: mode, model: model)
    }

    static func transcriptionConfiguration(
        mode: ModeConfig? = nil,
        transcriptionModelManager: TranscriptionModelManager
    ) -> TranscriptionRuntimeConfiguration? {
        transcriptionConfiguration(
            from: transcriptionModelResolution(
                mode: mode,
                transcriptionModelManager: transcriptionModelManager
            )
        )
    }

    static func transcriptionConfiguration(
        from resolution: ModeTranscriptionModelResolution
    ) -> TranscriptionRuntimeConfiguration? {
        guard
            case .available(let mode, let model) = resolution
        else {
            return nil
        }

        let configuredLanguage = TranscriptionLanguageSupport.validLanguageOrFallback(
            mode.selectedLanguage,
            for: model,
            realtimeEnabled: mode.isRealtimeTranscriptionEnabled
        )
        // Resolved here because this runs at recording start: the keyboard the
        // user had when they pressed the shortcut is the one that counts, and
        // switching layouts mid-sentence must not change the decode.
        let languageCandidates = KeyboardLanguagePolicy.recordingLanguages(
            configuredLanguage: configuredLanguage,
            for: model
        )
        let language = languageCandidates.first ?? configuredLanguage

        return TranscriptionRuntimeConfiguration(
            mode: mode,
            model: model,
            language: language,
            languageCandidates: languageCandidates,
            isRealtimeEnabled: TranscriptionRealtimeSupport.isEnabled(
                for: model, modeValue: mode.isRealtimeTranscriptionEnabled)
        )
    }

    static func transcriptionFormattingConfiguration(mode: ModeConfig? = nil) -> TranscriptionFormattingConfiguration {
        let mode = mode ?? ModeManager.shared.currentEffectiveConfiguration

        return TranscriptionFormattingConfiguration(
            mode: mode,
            isTextFormattingEnabled: mode?.isTextFormattingEnabled
                ?? UserDefaults.standard.bool(forKey: "IsTextFormattingEnabled")
        )
    }

    static func currentEnhancementConfiguration(
        mode: ModeConfig? = nil,
        enhancementService: AIEnhancementService,
        aiService: AIService
    ) -> EnhancementRuntimeConfiguration {
        let mode = mode ?? ModeManager.shared.currentEffectiveConfiguration
        let provider = resolvedProvider(
            providerName: mode?.selectedAIProvider,
            aiService: aiService
        )
        let prompt =
            provider == .voiceInkRefine
            ? nil
            : resolvedPrompt(
                promptId: mode?.selectedPrompt,
                enhancementService: enhancementService
            )
        let modelName = resolvedEnhancementModelName(
            provider: provider,
            configuredModelName: mode?.selectedAIModel,
            aiService: aiService
        )

        return EnhancementRuntimeConfiguration(
            mode: mode,
            isEnabled: mode?.isAIEnhancementEnabled ?? false,
            prompt: prompt,
            provider: provider,
            modelName: modelName,
            useClipboardContext: provider == .voiceInkRefine ? false : mode?.useClipboardContext ?? false,
            useSelectedTextContext: provider == .voiceInkRefine ? false : mode?.useSelectedTextContext ?? true,
            useScreenCaptureContext: provider == .voiceInkRefine ? false : mode?.useScreenCapture ?? false
        )
    }

    static func outputConfiguration(mode: ModeConfig? = nil) -> OutputRuntimeConfiguration {
        let mode = mode ?? ModeManager.shared.currentEffectiveConfiguration

        return OutputRuntimeConfiguration(
            mode: mode,
            outputMode: mode?.outputMode ?? .paste,
            customCommand: mode?.customCommand
        )
    }

    private static func resolvedPrompt(
        promptId: String?,
        enhancementService: AIEnhancementService
    ) -> CustomPrompt? {
        guard let promptId,
            let uuid = UUID(uuidString: promptId)
        else {
            return nil
        }

        return enhancementService.allPrompts.first { $0.id == uuid }
    }

    private static func resolvedProvider(
        providerName: String?,
        aiService: AIService
    ) -> AIProvider? {
        if let providerName {
            guard let provider = AIProvider(rawValue: providerName) else {
                return nil
            }
            return aiService.connectedProviders.contains(provider) ? provider : nil
        }

        return aiService.connectedProviders.first
    }

    private static func resolvedEnhancementModelName(
        provider: AIProvider?,
        configuredModelName: String?,
        aiService: AIService
    ) -> String? {
        guard let provider else { return nil }

        if provider == .localCLI {
            return nil
        }

        if provider == .voiceInkRefine {
            return provider.defaultModel
        }

        let models = aiService.availableModels(for: provider)
        if let configuredModelName,
            !configuredModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            (provider.supportsCustomModelID || models.isEmpty || models.contains(configuredModelName))
        {
            return configuredModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let firstModel = models.first {
            return firstModel
        }

        return provider.defaultModel
    }
}
