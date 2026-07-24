# Porting the Handy multilingual-dictation fixes to VoiceInk

A detailed, implementation-level spec of every behavioural change made in the
sibling fork **flexi767/Handy** (Tauri/Rust + TS) while making follow-keyboard
multilingual dictation reliable, written so each can be **re-implemented in
VoiceInk** (Swift/macOS) from the clean base.

Each item is: **the rule → why (the bug it fixes) → exact parameters → VoiceInk
porting notes** against the real Swift entry points. Order is implementation
dependency order.

VoiceInk is in several ways an *easier* target than Handy was: `LibWhisper.swift`
builds `WhisperFullParams` directly (decode knobs are one line, no wrapper), the
Whisper path already has the raw sample buffer (clip length is trivial), and the
language flows through one value — `TranscriptionRequestContext.language`
(`nil` = auto), fed from `UserDefaults "SelectedLanguage"`.

### VoiceInk entry points referenced below

- `Transcription/Engine/TranscriptionService.swift` — `TranscriptionRequestContext { language: String?, prompt: String? }`; language default read from `SelectedLanguage`.
- `Transcription/Whisper/WhisperTranscriptionService.swift` — `transcribe(audioURL:model:context:)`; calls `whisperContext.setLanguage(context.language)` then `fullTranscribe(samples:)`.
- `Transcription/Whisper/LibWhisper.swift` — builds `WhisperFullParams` (`params.language`, `params.temperature = 0.2`, …). **This is where whisper decode knobs go.**
- FluidAudio provider(s) — parakeet/nemotron path (forced-language, no translation behaviour).
- `NLLanguageRecognizer` (Foundation) — already used by the earlier wip branch.

---

## 1. Follow-keyboard language resolution

**Rule.** Add a `"follow_keyboard"` sentinel as a possible `SelectedLanguage`
value. When set, resolve the language for a recording from the **active macOS
keyboard layout** at record start, reduced to a base subtag (`en-US` → `en`).
Hardcode no language list — read whatever BCP-47 tag the layout advertises and
let the model's supported-language set constrain it.

**Why.** The whole feature: transcribe whichever of the user's keyboard
languages they are speaking, without manually switching the app's language.

**Parameters.** Base subtag = lowercase primary component of the BCP-47 tag.

**VoiceInk porting notes.**
- Read the layout with Carbon TIS: `TISCopyCurrentKeyboardInputSource()` +
  `TISGetInputSourceProperty(_, kTISPropertyInputSourceLanguages)`.
- **Main-thread caveat (this cost Handy three commits):** the *enumeration*
  `TISCreateInputSourceList` asserts the main dispatch queue and **aborts** the
  process if called off it. The single *current-source* lookup does **not**
  enumerate and is safe anywhere. VoiceInk transcription runs in async tasks, so
  wrap any `TISCreateInputSourceList` call in `DispatchQueue.main.sync { }` (or
  cache the enabled list on the main thread at record start). Reading only the
  current source needs no hop.
- Resolve at record start and pass the result as `TranscriptionRequestContext.language`.

---

## 2. Auto-detect on long clips, force the layout on short clips

**Rule.** For a **detection-capable** model in follow-keyboard mode:
- **clip ≥ 1.5 s** → leave the language on **auto** (`context.language = nil`);
- **clip < 1.5 s** → **force the active layout's language**.

Explicit (non-follow-keyboard) choices are always forced. Must-pick models
(no auto-detect) are always forced.

**Why.** Two opposite failures forced this split:
- Forcing the layout on a *long* clip is harmful: **whisper.cpp translates into
  the forced language rather than transcribing** when the audio is not in that
  language (speaking Bulgarian with an English layout produced fluent English).
- Auto-detect on a *short* (~1 s) clip is unreliable — a one-second Bulgarian
  "работи" gets detected as Italian. On so little audio the active keyboard is a
  far stronger signal than the guess.

**Parameters.** `SHORT_CLIP_FORCE_KEYBOARD_SECS = 1.5`. Clip seconds =
`samples / 16000`.

**VoiceInk porting notes.**
- `WhisperTranscriptionService` already has the sample buffer (`fullTranscribe(samples: data)`); compute `Double(data.count) / 16000.0` before `setLanguage`.
- Only apply the short-clip forcing to the whisper.cpp path. **FluidAudio /
  Nemotron (parakeet arch) does not translate on a forced language** — it just
  produces worse output — so the "don't force long clips" half is
  whisper-specific. For FluidAudio you may prefer to always force the resolved
  keyboard language (that was VoiceInk's original wip behaviour).
- Caveat to accept: short-clip forcing assumes the keyboard matches the spoken
  language (the normal case). Mismatch on a short clip → translation.

---

## 3. Whisper decode knobs (context bleed + short-clip hallucination)

**Rule.** On every whisper.cpp run, set `condition_on_prev_tokens = false`.

**Why.** Saying "just this" came back as "Bis zum nächsten Mal." (an unrelated
German farewell) shortly after a German dictation. whisper.cpp conditions on the
previous transcript's tokens, and when a clip is too short to constrain the
decoder it completes from that context instead of the audio. The session/context
is reused across recordings, so the bleed carries between dictations.

**Parameters.** `condition_on_prev_tokens = false`. Optionally also consider
`no_speech_thold`, `logprob_thold`, `compression_ratio_thold` to suppress
low-confidence/looping output — but leave these at defaults unless evidence
demands, since they also drop legitimate short speech.

**VoiceInk porting notes.**
- One line in `LibWhisper.swift` where `WhisperFullParams` is built (next to
  `params.temperature = 0.2`): `params.no_context = true` (the whisper.cpp field
  corresponding to "do not condition on previous tokens"; confirm the exact
  field name in the vendored whisper.h — historically `no_context`).
- This is strictly simpler than Handy, which had to route it through
  `transcribe-cpp`'s `WhisperRunOptions`. VoiceInk owns the params struct.

---

## 4. Wrong-language recovery

A safety net: when the primary transcript is in a language the user does not
type, retry the retained audio with the language forced, and keep the retry only
if it validates. Four sub-parts, all learned the hard way in Handy.

### 4a. Conflict detection (validator)

**Rule.** Detect the transcript's language with `NLLanguageRecognizer`. Report a
conflict only when the dominant language is **confidently** outside the user's
enabled keyboard languages. Fail open (no conflict) on empty/uncertain input.

**Parameters.** Multi-word: conflict if outside-candidate probability mass ≥ 0.85,
or the top hypothesis has confidence ≥ 0.90 and its base subtag is not a
candidate. Single word: require outside mass ≥ 0.85 (short text is noisy).

**VoiceInk notes.** VoiceInk's earlier wip `TranscriptLanguageValidator` already
did exactly this with the same thresholds — reuse it.

### 4b. Retry on the loaded primary first

**Rule.** Retry on the **already-loaded primary model** forced to each candidate,
*before* loading any other model. Skip this and fall back to a different model
only when the primary cannot be given a language (a detect-only engine would just
repeat itself).

**Why.** Handy's recovery always loaded a *different*, weaker model (parakeet)
even though the strong primary (Whisper) was in memory and got the same phrase
right seconds later. Reusing the loaded primary is more accurate and avoids a
second model load.

**VoiceInk notes.** In the recovery step, re-invoke the *same* provider/model
with `TranscriptionRequestContext(language: forced, prompt: nil)` rather than
switching to the Nemotron model. Only route to a different model if the primary
is not language-forceable.

### 4c. Candidate ordering — English last

**Rule.** Order the recovery candidates so **English is tried last**, keeping the
other keyboard languages in active-first order.

**Why.** Recovery keeps the first candidate that validates. Forcing English on
non-English audio yields fluent English (Whisper's translation target) that
always validates — so trying `en` first masks a correct result from another
candidate ("Работи перфектно" was overwritten by "Put down perfect, no?").
English stays reachable last for genuinely-English short/noisy clips.

**VoiceInk notes.** Pure ordering function over the candidate array; trivial.

### 4d. Match candidates on the base subtag

**Rule.** When checking whether the fallback model can serve a candidate, and
when forcing it, match on the **base subtag** (`bg`) against the model's language
list, then force the model's own code. Do not use exact string equality.

**Why.** The recovery model advertised full locales (`bg-BG`) while candidates
were base subtags (`bg`); exact match skipped every candidate, so recovery
selected the model but never actually ran it.

**VoiceInk notes.** VoiceInk's `KeyboardLanguagePolicy` already canonicalised via
`Locale.canonicalLanguageIdentifier` on both sides — that approach is correct and
avoids this bug; keep it.

---

## 5. Active-keyboard-language indicator (UI)

**Rule.** Show the active layout's two-letter uppercase code (e.g. `BG`, `EN`) in
the recorder UI, near the status indicator — **not** consuming layout space that
would resize the waveform.

**Why.** Makes a keyboard/speech mismatch obvious at a glance (the root of most
confusion: keyboard on English while speaking Bulgarian).

**VoiceInk notes.** VoiceInk's earlier wip already had a `RecorderLanguageCode`
view — reuse it. Feed it the active-layout code (`TISCopyCurrentKeyboardInputSource`
primary language, uppercased). Position it as an overlay/leading item, not inside
a fixed-width centered stack, so it does not shrink the waveform (in Handy,
putting it in a grid cell squeezed the waveform — SwiftUI equivalent: use an
overlay/`ZStack` alignment rather than an `HStack` sibling of the waveform).

---

## 6. Adaptive recording waveform (optional)

**Rule.** Normalise each visualiser band against its own **adaptively-tracked
noise floor** rather than a fixed dB threshold; let the floor fall quickly to a
new quiet level and rise slowly, and never raise it on loud (speech) frames.

**Why.** A fixed floor made the waveform barely move on quiet built-in mics.

**Parameters.** ~45 dB dynamic range above the floor; floor attack ≈ 0.2,
release ≈ 0.001; never update the floor on frames > ~10 dB above it.

**VoiceInk notes.** Only relevant if VoiceInk's recorder has an FFT-band
visualiser with the same fixed-floor problem; otherwise skip. This one is
independent of everything else.

---

## Process lessons worth carrying over

- **Suspect the build before the code.** In Handy the same crash persisted
  through several *correct* fixes because incremental compilation was reusing a
  stale object file; a clean rebuild fixed it instantly. If a change "isn't
  taking", do a clean build before re-diagnosing. (Swift/Xcode analogue: clean
  build folder / derived data.)
- **Log the decision, verify from logs.** Most of these bugs were invisible
  without logging the resolved language, the recovery candidate order, and the
  per-candidate forced result. Add those logs first.
- **Short clips are short for two reasons** — a genuinely brief phrase (forcing
  the layout helps) or a *truncated* longer phrase (nothing routing does can
  help; it is a capture problem — key released early, or ~57 ms lost to mic
  stream cold-start). Consider always-on mic to remove the cold-start loss.
- **English is a trap candidate** whenever whisper.cpp is in play, because it is
  the translation target. Treat it as special (tried last) rather than as just
  another language.

## Model note

Handy switched the primary to **Whisper Large v3 Turbo** specifically because it
handles Bulgarian far better than the NVIDIA parakeet/nemotron models (more
Cyrillic/multilingual training data), despite a nominally similar general
accuracy score. If VoiceInk's Bulgarian quality is the goal, model choice matters
more than any routing fix — a strong multilingual Whisper as primary does most of
the work, with recovery as the backstop.
