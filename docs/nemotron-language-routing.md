# Nemotron language routing — decisions and evidence

Why keyboard-driven language selection is built the way it is on Nemotron
Multilingual. Every decision here was measured, not reasoned about; the
measurements are reproducible by replaying retained WAVs through
`StreamingNemotronMultilingualAsrManager` with one variable changed at a time.

Implementation: `VoiceInk/Transcription/Engine/KeyboardLanguagePolicy.swift`,
`TranscriptLanguageRecovery.swift`.

---

## 1. The language hint is `setLanguage` only. Never `setForcedPrefix`.

`setLanguage` selects the encoder prompt id. `setForcedPrefix(true)` additionally
seeds the decoder LSTM with the lang-tag token and sets `lastToken` to it, so the
model stops emitting its own leading `<|xx|>` tag.

**It deletes the first word.** 30 retained clips, same audio, same `en-US` hint,
forced prefix the only variable:

| plain | forced prefix |
| --- | --- |
| **Are** we still on the old model? | we're still on the old model |
| **Crops out** the car that he detects | the car that he detects |
| **We** had a pretty long run trying… | had a pretty long run trying… |
| **Did** you commit everything | you commit everything |

8/30 clips changed their opening word; mean length stayed flat (37.3 → 37.1)
while whole leading words disappeared.

This is the regression that made the previous attempt unusable — "missing the
first word from every dictation." Do not re-enable it, and do not assume a newer
FluidAudio fixes it without re-running the A/B.

A plain hint is safe: 23/30 clips keep a byte-identical first word versus
auto-detect, and where they differ the forced result is longer, never truncated.

## 2. The keyboard language is forced at every clip length. No duration threshold.

Handy and the earlier VoiceInk branch both had a short-clip rule: below
~1.5–5 s force the keyboard language, above it keep auto-detect. It is not
ported, and the `ShortClipLanguageLockSeconds` default it read is inert.

The threshold existed to answer "when do we stop trusting auto-detect?" Choosing
*Installed keyboard languages only* answers that globally — the language never
comes from detection — so there is nothing left for a threshold to decide.

The rule's other half was protecting against a **Whisper** failure: forced a
language it is not hearing, whisper.cpp translates rather than transcribes
(Bulgarian spoken on an English layout came back as fluent English, and
`params.translate = false` does not prevent it). **Nemotron does not do this.**
Forcing `de-DE` on Bulgarian audio returns *empty*, not invented German — and an
empty primary is itself a recovery trigger. So forcing at every duration is safe
here in a way it would not be on Whisper.

If the short-clip rule is ever ported, it belongs on the Whisper path only, and
only for the Auto-detect configuration.

## 3. Auto-detect stays auto on the primary pass.

When the user picks Auto-detect rather than the keyboard option, the primary runs
on auto and the keyboard languages become recovery candidates only. Coercing
auto into a keyboard language behind the user's back was "the big bug" of the
earlier branch: whisper.cpp received an unrecognised code, silently fell back to
English, and translated.

Cost of this choice, measured: auto-detect returned **empty on 3/30 clips** that
a forced language transcribed correctly, and produced wrong-script output on
another — "Put the text of the title next to the icon" came back as
`Пототекс в Дитно не кнопर`. Recovery catches both, at the price of a second
inference pass.

Wrong-script output was expected to be the hole here — the assumption being that
with Bulgarian enabled, any Cyrillic output validates. **Measured false.** Apple's
recogniser separates Bulgarian from Russian cleanly, so a Cyrillic decode that is
not Bulgarian is rejected and recovery fires. Candidates `bg`/`de`/`en`:

| transcript | verdict | top hypotheses |
| --- | --- | --- |
| `Каких хипари привели са наистина` (wrong decode) | rejected | ru 1.00 |
| `Понякави пари привели ли са на истины` (wrong decode) | rejected | ru 0.48, kk 0.40, bg 0.12 |
| `Пототекс в Дитно не кнопе` (nonsense) | rejected | ru 1.00 |
| `Работи перфектно, благодаря ти много` (real Bulgarian) | accepted | bg 1.00 |
| `Работи` (one real Bulgarian word) | accepted | bg 0.99 |

What recovery cannot repair is the *audio*: probing `bg-BG` on that clip returns
the same wrong words, so nothing validates and the primary is preserved. That is
the intended outcome — a language router cannot fix a bad transcription.

### Why the empty ones are empty

The three failures were `Test, test, test.` (1.36 s), `Testing.` (1.01 s) and
`Natively.` (1.20 s). Each hypothesis was tested by changing one variable:

| suspected cause | test | result |
| --- | --- | --- |
| final chunk never flushes | trailing silence 0 / 1 / 3 / 6 s | no effect — empty at every padding |
| clip too short | truncate a working 7.8 s clip to 1.0 s | transcribes fine under `auto` |
| audio too quiet | peak/RMS of all 30 clips | failures sit mid-pack; quieter clips work |
| the prompt id | same audio, `auto` vs `en-US` | **empty vs correct, every time** |

So it is not truncation, not duration, and not level — it is the prompt id.
Under `auto` (id 101) the model has to resolve the language from the audio
itself, and on a brief, isolated utterance surrounded by silence there is not
enough evidence to commit. The transducer resolves that ambiguity by emitting
blanks rather than guessing, so the output is nothing at all rather than a
wrong-language guess. A forced prompt id removes the ambiguity and it decodes.

Two refinements worth keeping:

- Adding more of the same speech can rescue `auto` but does not always:
  concatenating `Testing.` with itself yields "Testing testing" under `auto`,
  while doing the same to `Natively.` still yields nothing.
- Below roughly 0.5 s, output is empty under **any** prompt id — a 0.45 s slice
  of speech that works at 1.0 s returns nothing under both `auto` and `en-US`.
  That is the model's floor, not a routing problem.

This is the single strongest argument for the keyboard option: with it the
primary pass always carries a prompt id, so this class of failure cannot occur.

On Auto-detect it is handled after the fact, with two rules specific to it:

- **Probes run in keyboard order, active layout first.** The English-last rule
  exists to stop fluent English masking a correct result; with an empty primary
  there is no result to mask, and the active layout is the user's own signal.
- **Validation cannot veto the recovery.** If nothing validates, the first
  non-empty probe is kept anyway. The transcripts recovered here are exactly the
  ones the validator is worst at — a one- or two-word utterance spreads its
  probability so thinly that a correct result is rejected on noise ("Test test
  test" reads as `fr 0.20 / it 0.18 / pl 0.14`, English nowhere in the top three)
  — and handing the user nothing is strictly worse than an unconfirmed
  transcription. The fallback is scoped to the empty case; a non-empty primary
  is still only replaced by something that validates.

## 4. Only models whose language parameter is a real hint get the option.

`KeyboardLanguagePolicy.supportsFollowKeyboard(for:)` gates on capability, not on
a model name. Nemotron takes an encoder prompt id; whisper.cpp takes a decoder
language token. Both qualify.

**Parakeet does not.** FluidAudio's `Language` for the Parakeet family resolves to
`TokenLanguageFilter` — a Unicode *script* filter over the joint network's argmax.
Setting `bg` does not say "this is Bulgarian", it says "never emit a token
containing Latin letters", which suppresses the leading word whenever the clip
opens on a name, a brand, or the wrong script. Parakeet is why the option is
absent rather than merely discouraged.

## 5. Recovery has two triggers with different burdens of proof.

- **Rejected** — primary empty, or confidently outside the user's languages. Any
  validated retry replaces it.
- **Suspect** — primary accepted, but a candidate's writing system never appeared,
  so it may be a romanisation. A probe must read better by **0.15** before it
  replaces something already plausible; otherwise genuine Latin dictation gets
  over-converted the moment a Cyrillic keyboard is installed.

Every candidate is probed and the best-reading result wins, rather than the first
that merely validates — with two or three keyboards the extra inference is cheap,
and "validates" is a weak bar when the primary already looked fine.

Retry order: missing-script candidates first, **English always last**. Forcing
English yields fluent English that validates for almost any audio and would mask
a correct result from another candidate.

Each retry is validated against *the single language it was forced to*, not the
whole candidate set — a retry that drifted back to the wrong language must not
pass because some other keyboard would have explained it.

Failing open is the invariant: the primary survives an empty retry, a failed
retry, a cancelled retry, and a retry that does not validate.

## 6. Nemotron forces the realtime path, so the language must be frozen upstream.

`FluidAudioModelManager.requiresRealtime` is true for Nemotron, so
`TranscriptionRealtimeSupport.isEnabled` returns true regardless of the mode's
stored value. The keyboard language therefore has to reach
`FluidAudioNemotronStreamingProvider.connect(model:language:)` already resolved.
It is snapshotted in `ModeRuntimeResolver.transcriptionConfiguration` at recording
start and never re-derived from the live keyboard — switching layouts
mid-sentence must not change the decode.

## 7. Carbon TIS reads are main-thread-only and cached.

Every Text Input Source call asserts the main dispatch queue on macOS 26 —
`TISGetInputSourceProperty` included, via `isValidateInputSourceRef` — and aborts
the process rather than failing. The assert only fires while the input-source
cache is cold, just after login, so an off-main read can work for a whole session
and then kill the app on the next boot.

Reads are also **cached** rather than hopped to main with `DispatchQueue.main.sync`:
`validLanguageOrFallback` is reachable from the transcription actors, and a sync
hop from there would deadlock against a main thread awaiting that same
transcription. A cold cache off the main thread reports no keyboards, which
degrades to auto-detect rather than to a wrong language.

---

## Model facts worth knowing

From `metadata.json` in the installed model directory
(`FluidAudio/Models/nemotron-multilingual/multilingual/1120ms`):

- `prompt_dictionary` maps **121 locale keys onto 84 distinct prompt ids**.
  `bg-BG` and `bg` both map to id 30; `default_prompt_id` 101 is `auto`.
- `LanguageDictionary.nemotronMultilingual` exposes **29** of them. The model
  supports far more, including European languages VoiceInk does not offer —
  `lt`, `lv`, `sl`, `mt`, `el`, `nn` — alongside `af, am, ay, az, bn, fa, gn, gu,
  ha, haw, he, hy, id, ig, ka, km, kn, ku, ky, ln, mi, ml, mr, ms, nah, ne, ny,
  or, qu, rw, si, sm, so, sw, ta, te, tg, th, to, ur, uz, yo, zu`. Widening the
  dictionary is a one-line change if a user's keyboard needs one of them.
- Distinct hints produce distinct output, so the prompt id is genuinely applied:

  ```
  auto    Каких хипари привели са наистина
  bg-BG   Каких хипари привели са наистина
  ru-RU   Яков хипари привели са наистину
  de-DE   (empty)
  ```

## Known limits

- **Forcing `bg-BG` does not fix bad Bulgarian.** On the reference clip it gives
  the same wrong text as auto, because auto had already detected Bulgarian
  correctly — the model simply transcribes that clip badly. Keyboard routing
  fixes language *selection*, not acoustic quality. Mic level and utterance
  length matter more.
- **The script trigger is dormant for `bg`/`de`/`en`.** Apple's recogniser scores
  romanised Bulgarian as Croatian/Czech/Hungarian — all outside that candidate
  set — so the text validator already rejects it and recovery fires without the
  script check. The trigger only earns its keep when a confusable keyboard
  (Croatian, Czech, Slovak, Polish, Hungarian) is also enabled.
- **No model-side language signal exists on Nemotron.** It emits no lang-tag
  tokens in practice, so both `detectedLanguage()` and
  `lastDecodeStats().detectedLanguage` return nil on every measured run (16, 27
  and 31 tokens decoded, no tag among them). Any design that wants the model's
  own opinion of the language has to use Whisper's `whisper_full_lang_id()`
  instead — but see below for why that is not currently worth wiring up.

## Why the primary stays Nemotron, and why there is no short-clip lock

Nemotron is weak on short Bulgarian and no amount of context padding reaches it.
The same clips through Whisper large-v3-turbo forced to `bg`:

| Nemotron | Whisper large-v3-turbo |
| --- | --- |
| `Сега Работ` | `Сега работи.` |
| `Сега Робот` | `Сега работи.` |
| `Сега работ` | `Сега работи.` |
| *(empty)* | `работи` |
| *(empty)* | `работи` |
| `Нищо не работи` | `Ништо не работи.` |
| `Как работи` | `Как работим?` |
| `Check now please` | `чекната, плее.` |

Whisper recovers every dropped ending and both empty transcripts. It is also
**worse** on the two Nemotron got right, and it mangled an English utterance into
Cyrillic — that last row is the translation hazard, not a mishearing: forced into
a language it is not hearing, Whisper transliterates rather than transcribes.

This fork nevertheless stays on Nemotron. The sibling **Handy** install already
runs Whisper large-v3-turbo, so the strong-Bulgarian case is covered there, and
VoiceInk keeps the fast local path. That is a deployment decision, not a quality
judgement — do not "upgrade" the model here without checking that first.

It is also why **the short-clip language lock is not ported**. Its whole purpose
is to keep Whisper on auto-detect for longer clips so a keyboard/speech mismatch
cannot silently translate. Nemotron does not translate — handed the wrong
language it returns empty — so the rule protects against a failure mode this
model does not have. If the primary ever becomes Whisper, the lock becomes
mandatory, not optional.

## Claims from the earlier branch that did not survive measurement

Both of these were inherited as fact from `MULTILINGUAL_DICTATION_CHANGES.md` and
used to justify machinery. Re-measure before rebuilding either.

- **"Bulgarian read as Russian looks Bulgarian to `NLLanguageRecognizer`."** False
  — it scores those decodes as Russian at 1.00 and 0.48, both rejected. This was
  the entire justification for surfacing `whisper_full_lang_id()` as a
  side-channel through `LibWhisper` → `WhisperTranscriptionService` → the
  registry. With the premise gone, that machinery has no job to do.
- **"Romanised Bulgarian passes the validator."** False for a `bg`/`de`/`en`
  keyboard set — nine phrases tested, all rejected outright. The script check
  still earns its keep, but only when a confusable keyboard is also enabled.
