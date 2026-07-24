# Multilingual dictation work — change log & reference

This document summarizes **all** changes made to this fork while chasing reliable
multilingual (English / German / Bulgarian) dictation, up to and including the
`wip/multilingual-dictation-experiments` branch.

`main` has been reset to the **clean fork base `69ed170` "Release VoiceInk 2.0"**
(the merge-base with upstream `Beingpax/VoiceInk`). Every change described below
lives on the **`wip/multilingual-dictation-experiments`** branch (pushed to
`origin` = `flexi767/VoiceInk`), not on `main`.

---

## Branch / commit map

```
69ed170  Release VoiceInk 2.0          <- upstream base = current main (clean)
  │  (flexi767's own pre-existing work)
  ├─ dadbb90  feat: add keyboard-aware Nemotron transcription
  ├─ 367cb65  feat: recover dictation across keyboard languages
  ├─ b3a1865  fix: derive Nemotron languages from keyboards
  ├─ 0d83482  fix: clarify installed keyboard language option
  │  (session work)
  ├─ d1124ee  Fix Nemotron keyboard-language recovery for transliterated speech
  ├─ db38712  Fix multilingual transcription language routing (detection-capable models)
  └─ 89c2517  Gate wrong-language recovery on whisper's own detected language   <- wip HEAD
```

To resurrect the full experimental stack: `git checkout wip/multilingual-dictation-experiments`.

---

## Code changes (all on `wip`)

### 1. `d1124ee` — script-aware Nemotron recovery
`TranscriptLanguageRecovery.swift` / `KeyboardLanguagePolicy.swift`
- The wrong-keyboard recovery only re-ran when the text validator *rejected* the primary.
  Apple's `NLLanguageRecognizer` accepts short romanized output (Bulgarian dictated on a
  Latin keyboard → "Diktur na Bulgarski"), so recovery never fired.
- Added **script awareness**: detect the script of the primary vs the expected script of each
  candidate (Cyrillic/CJK/etc.). Force retry when a candidate's script is absent from the
  primary. Probe the other candidate languages, pick the best-scoring, with a +0.15 margin so
  genuine Latin dictation is never over-converted.

### 2. `db38712` — multilingual language routing for detection-capable models
`KeyboardLanguagePolicy.swift` / `TranscriptLanguageRecovery.swift` / `TranscriptionPipeline.swift`
- **The big bug:** `recordingLanguages()` ran the Nemotron keyboard validator on *every*
  model, coercing a valid `"auto"` into the literal `"keyboard"` sentinel. whisper.cpp got an
  unknown language code → silently fell back to English. Because the language token controls
  what the decoder *emits*, this is effectively a **translation** (Bulgarian → English), not a
  mislabel — and `params.translate = false` does not help. Non-Nemotron models now pass their
  configured language through untouched, and on `auto` also expose the keyboard languages as
  recovery candidates.
- Recovery is **no longer Nemotron-only** — detection-capable models (Whisper) get it too.
- Recovery **tries English last** (forcing `en` yields fluent English that always validates and
  masks a correct result) and treats `"auto"` as having no expected language.
- **Short-clip language lock:** Whisper language ID is unreliable on brief utterances (flips
  en/bg/ru). For clips shorter than `ShortClipLanguageLockSeconds` (UserDefaults, default 5s)
  on an `auto` model, force the **active keyboard's** language; longer clips keep `auto`.

### 3. `89c2517` — gate recovery on whisper's own detected language
`LibWhisper.swift` / `WhisperTranscriptionService.swift` / `TranscriptionServiceRegistry.swift`
/ `TranscriptLanguageRecovery.swift` / `TranscriptionPipeline.swift`
- The text validator cannot tell a Cyrillic-but-wrong-language decode apart (Bulgarian read as
  Russian both look "Bulgarian" to `NLLanguageRecognizer`) and accepted it.
- Surface whisper's own `whisper_full_lang_id()` as a **side-channel property**
  (`WhisperContext.detectedLanguageCode` → `lastDetectedLanguage` → registry →
  `selectTranscript(detectedLanguage:)`), avoiding a `-> String` protocol change across all
  providers. Recovery now **forces retry whenever the detected language is outside the user's
  keyboard languages** (Bulgarian misdetected as Russian/Icelandic is caught and re-run forced).

---

## Runtime / configuration changes (UserDefaults + system, NOT in git)

These were applied to the installed app's settings, separate from code:

| Area | Change | Key / location |
| --- | --- | --- |
| Enhancement provider | Local CLI (claude) → Ollama qwen2.5:3b → **MLX Qwen3-4B-Instruct-2507-4bit** | Custom provider in `customAIProviders` |
| Enhancement prompt | seeded, then "strict", then **language-lock** (don't translate; keep input language) | `customPrompts` id `…0001` |
| MLX runner | `mlx_lm.server` in `~/.mlx-voiceink/venv`, persistent LaunchAgent `~/Library/LaunchAgents/com.voiceink.mlx.plist` on `:8080` | — |
| Ollama | installed via brew, later `brew services stop ollama` (kept as fallback) | — |
| Transcription model | Nemotron ↔ **Whisper `ggml-large-v3-turbo`** (+ CoreML encoder) experiments | mode `selectedTranscriptionModelName` |
| Whisper initial_prompt | cleared the English `"Hello, how are you…"` bias | `TranscriptionPrompt`, `SelectedLanguage=auto` |
| Microphone | MacBook mic (recording ~-46 dBFS, too quiet) → **MateView USB mic** (~-31 dBFS) | `selectedAudioDeviceUID` |
| Enhancement | currently **disabled** | mode `isAIEnhancementEnabled=false` |

## App build / signing

- The installed app is a **self-signed `LOCAL_BUILD`** (not the original Developer-ID release):
  `xcodebuild … CODE_SIGNING_ALLOWED=NO … SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) LOCAL_BUILD'`
  then `codesign --force --deep --sign "Apple Development: i@jlzov.com" --entitlements VoiceInk/VoiceInk.local.entitlements`.
- **`LOCAL_BUILD` is mandatory** — otherwise the `dictionary` SwiftData store uses CloudKit and
  crashes on launch without the iCloud entitlement (which `VoiceInk.local.entitlements` omits).
- Re-signing with a new identity resets macOS TCC → must re-grant **Accessibility** (+ mic).
  VoiceInk's global hotkey uses an intercepting `CGEvent.tapCreate`, so **Accessibility alone is
  sufficient; Input Monitoring is not needed** (unlike what the UI may imply).

## Key findings (why plain rollbacks don't fix things)

1. **Forcing a language Whisper is not hearing makes it translate**, not mislabel. Leave
   detection-capable models on `auto` + recover afterwards.
2. **First-word drop was OUR regression, not the audio path.** ~~It's a realtime streaming
   artifact; Parakeet V3 (non-streaming) also drops it, so it's the FluidAudio path.~~
   **CORRECTED 2026-07-24:** the clean `69ed170` 2.0 base running **Parakeet V3 + `auto` +
   built-in mic** keeps the first word on every clip. Same model, same FluidAudio path — so the
   drop was introduced by the experimental stack (keyboard-routing / recovery / short-clip lock,
   and/or the forced-language + realtime experiments), not by FluidAudio or by "old code." Going
   back to pristine 2.0 *fixed* it. Do not re-blame the base for this.
3. **Short/fast Bulgarian garbles even offline** (detected as Arabic/Icelandic) — the model
   genuinely lacks signal; no routing logic fixes it. Mic level and enunciation/length matter most.
4. **Microphone level was a real culprit** — the MacBook mic recorded ~20 dB too quiet; the
   MateView mic fixed the level (English survived low SNR, Bulgarian did not).
5. VoiceInk does **not** emit to macOS unified logging — debug by replicating logic in a
   standalone `swift` script and by re-transcribing the saved `Recordings/*.wav` offline with
   `mlx_whisper`.

## Restoring the Whisper stack later

1. `git checkout wip/multilingual-dictation-experiments`
2. Build + sign + install (see build/signing section).
3. Set the mode: transcription `ggml-large-v3-turbo`, language `auto`, realtime off; keep the
   MateView mic. Grant Accessibility after install.
