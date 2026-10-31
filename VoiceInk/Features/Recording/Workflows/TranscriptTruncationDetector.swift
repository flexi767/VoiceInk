import Foundation

/// Flags a streaming transcript that stopped short of the speech it was given,
/// so the pipeline can re-decode the retained audio in one batch pass.
///
/// Nemotron streaming commits only what it has finished when the key is
/// released; on quiet audio that can be the first word of a sentence (`Ich`
/// from 3.2 s of `Ich spreche gerade auf Deutsch`). A batch decode has no such
/// deadline. Measured 2026-11-01 over 389 Nemotron dictations of 2 s or more:
/// 16 came out under 2 characters per second, the shape of a cut-off sentence.
///
/// Empty transcripts are left to `TranscriptLanguageRecovery`, which probes
/// the other keyboard languages: an empty stream is as often the wrong
/// language as a truncated one, and a same-language re-decode of Bulgarian
/// audio forced to German would hand it a plausible-looking Latin result.
enum TranscriptTruncationDetector {

    /// Below this length a recording is too short to judge: a single word
    /// legitimately fills it.
    static let minimumDuration: TimeInterval = 2

    /// Letters per second of recording under which a transcript reads as cut
    /// off. Genuine dictation, silences included, sits well above it; fast
    /// speech is ~15.
    static let minimumLettersPerSecond = 2.0

    static func isTruncated(_ text: String, audioDuration: TimeInterval) -> Bool {
        guard audioDuration >= minimumDuration else { return false }
        let count = letters(text)
        guard count > 0 else { return false }
        return Double(count) / audioDuration < minimumLettersPerSecond
    }

    /// Whether the batch re-decode should replace the streamed transcript: only
    /// when it carries more letters. A retry that also came back short, or
    /// empty, keeps the stream's result.
    static func prefersRetry(_ retry: String, over primary: String) -> Bool {
        letters(retry) > letters(primary)
    }

    static func letters(_ text: String) -> Int {
        text.unicodeScalars.filter { $0.properties.isAlphabetic }.count
    }
}
