# Future improvement: Parakeet accuracy with Nemotron language fallback

**Status:** Deferred. This is an alternative to the keyboard-conditioned
Nemotron implementation and is not part of the initial three-language change.

## Goal

Keep Parakeet V3 as the normal transcription engine for its stronger English,
German, and Bulgarian accuracy while preventing mixed- or wrong-language output.

## Proposed flow

1. Snapshot the active macOS keyboard input source when recording begins and
   map it to `en-US`, `de-DE`, or `bg-BG`.
2. Transcribe once with Parakeet V3.
3. Classify the resulting text only among English, German, and Bulgarian.
4. Accept the Parakeet result when it agrees with the keyboard language or the
   classifier is inconclusive.
5. When the classifier confidently disagrees or detects mixed-language output,
   discard the first result and transcribe the same audio again with Nemotron,
   using the keyboard language as an exact prompt with forced-prefix decoding.
6. Deliver only the accepted result; the intermediate transcript must not enter
   history, clipboard output, analytics, or post-processing.

## Why this is a fallback rather than the primary design

Parakeet V3's FluidAudio language hint filters by writing system. It can
separate Bulgarian Cyrillic from Latin text, but it cannot force English rather
than German. Nemotron supports exact language prompts, but its published FLEURS
accuracy is lower for all three target languages. The hybrid preserves
Parakeet's result on the common path and pays the Nemotron latency and energy
cost only when needed.

## Open questions

- Choose and calibrate a local language classifier. Apple's Natural Language
  framework is the lowest-dependency candidate, but short dictations and proper
  nouns require an inconclusive state rather than a forced decision.
- Define confidence and mixed-language thresholds using representative English,
  German, and Bulgarian dictation captured from the target microphone.
- Decide whether Nemotron should stay warm alongside Parakeet. Keeping both
  loaded reduces fallback latency but increases memory and idle resource use.
- Add cancellation and progress handling for the second inference pass.
- Benchmark latency, energy, memory, and word error rate against always-forced
  Nemotron before enabling the hybrid by default.

## Acceptance criteria if revisited

- The classifier can return only English, German, Bulgarian, or inconclusive.
- Short or ambiguous utterances follow the keyboard language.
- A fallback never produces duplicate history or delivery events.
- Tests cover agreement, confident disagreement, mixed text, inconclusive text,
  cancellation, and Nemotron failure.
- Evaluation shows a meaningful accuracy benefit over always-forced Nemotron
  without unacceptable latency or battery cost.
