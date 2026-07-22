# Nemotron keyboard-language routing and recovery

**Status:** Implemented in this repository.

## Goal

When **Follow Keyboard** is selected, VoiceInk should prefer the language of
the keyboard that was active when recording began. If the user speaks another
language represented by one of their other enabled keyboards, VoiceInk should
retry the retained recording instead of returning a clearly wrong-language
transcript. The feature stays limited to the languages exposed by this
VoiceInk build and supported by the selected Nemotron model.

This is the VoiceInk/Core ML counterpart of Handy's wrong-keyboard recovery.
VoiceInk does not add Parakeet or GGUF: its initial transcription and every
recovery attempt use the existing prompt-conditioned Nemotron Core ML model.

## VoiceInk baseline retained by this work

The following earlier VoiceInk changes remain in place and are prerequisites
for the recovery feature rather than new model backends:

- Nemotron runs through FluidAudio/Core ML as VoiceInk's multilingual local
  model; VoiceInk does not share Handy's GGUF model files.
- The language picker exposes **Follow Keyboard**, English, German, and
  Bulgarian. That product allowlist is intentionally separate from the generic
  BCP-47 matching algorithm, so other builds can supply other supported locales
  without adding identifier-specific code.
- The recorder status window shows the frozen language beside its left-hand
  icon as a two-letter code. Its audio-level dots continue to reflect microphone
  amplitude only while recording.
- Local builds use the repository's persistent Apple Development signing
  configuration and `make local` replaces and launches `/Applications/VoiceInk.app`.
- `AGENTS.md` remains a symlink to `CLAUDE.md`, and the repository's code graph
  remains part of the review workflow.
- VoiceInk's recording history is already paginated rather than capped at 50,
  so Handy's history-limit change requires no VoiceInk port.

## Implementation tasks

- [x] Read each macOS input source's ordered
  `kTISPropertyInputSourceLanguages` BCP-47 metadata.
- [x] Map BCP-47 identifiers to model-supported locales generically: prefer an
  exact canonical match, then match the primary language subtag. Do not list
  keyboard identifiers or every possible language.
- [x] Use a localized keyboard-name match only when macOS supplies no language
  metadata.
- [x] At recording start, freeze the active keyboard language followed by the
  other enabled keyboard languages, de-duplicated by primary language and
  intersected with the model/build allowlist. Explicit language selections
  remain single-language and do not retry.
- [x] Validate Nemotron output with Apple's offline Natural Language framework.
  Reject a confident whole-result mismatch or a confident two-word span in a
  language outside the frozen candidates, while allowing legitimate mixed
  language and isolated names/brand tokens.
- [x] For one-word results, inspect the five strongest language hypotheses and
  trigger recovery only when at least 85% of their probability mass belongs to
  languages outside the frozen candidate set. This catches `Está.` without
  rejecting ambiguous names such as `Alice`, `Microsoft`, or `OpenAI`.
- [x] If the first result is suspicious or empty, replay the same saved audio
  through batch Nemotron with each frozen language forced, active keyboard
  first. Stop at the first result that validates for the forced language.
- [x] Fail open: if every retry is empty, invalid, cancelled, or errors, preserve
  the original non-empty transcript and recording.
- [x] Cover generic locale matching, candidate ordering, mixed-language
  acceptance, known bad outputs, the one-word rule, and retry selection with
  unit tests.

## Runtime flow

1. Recording starts and snapshots `active keyboard -> macOS BCP-47 language ->
   model locale`, followed by the user's other enabled and supported keyboard
   languages.
2. Streaming Nemotron runs with the active language forced. The two-letter
   recorder label shows that frozen primary language.
3. VoiceInk filters the model output and validates it before formatting,
   replacements, enhancement, or delivery.
4. A valid result continues normally. A suspicious/empty result reuses the
   retained audio file and runs batch Nemotron once per frozen candidate with
   that exact language forced.
5. The first validated retry is used. If none validates, VoiceInk returns the
   original usable result so dictation is never silently discarded.

## Behavioral boundaries and saved regressions

- The feature is for speaking in a language different from the selected
  keyboard. Choosing an explicit language disables cross-language retries.
- Mixed-language text is valid. `OpenAI тест` must remain accepted; the rule is
  that a substantial, confidently detected span must be explainable by an
  enabled candidate, not that the whole transcript uses one script.
- Known suspicious outputs that must trigger recovery include
  `Št je svârsza spokojna.`, `Ю шуднт хит ютуб, райт.`,
  `Моля ти протиміснимка.`, `Сега срещу вороно Богорский`, and `Está.`.
- Language recognition is evidence, not certainty. Low-confidence and
  ambiguous cases fail open to avoid destroying valid names or technical text.
