import Testing

@testable import VoiceInk

struct TranscriptTruncationDetectorTests {

    private typealias Detector = TranscriptTruncationDetector

    @Test func flagsAFirstWordFromALongRecording() {
        // The 2026-10-31 case: `Ich` from 3.2 s of a full German sentence.
        #expect(Detector.isTruncated("Ich.", audioDuration: 3.2))
        #expect(Detector.isTruncated("Да", audioDuration: 2.8))
    }

    @Test func acceptsCompleteDictation() {
        #expect(!Detector.isTruncated("Ich spreche gerade auf Deutsch.", audioDuration: 5.3))
        #expect(!Detector.isTruncated("Сега говоря на български.", audioDuration: 2.8))
    }

    @Test func leavesShortRecordingsAndEmptyTranscriptsAlone() {
        // A one-word answer fills a short recording.
        #expect(!Detector.isTruncated("Ja.", audioDuration: 1.5))
        // Empty is wrong-language recovery's case, not this one.
        #expect(!Detector.isTruncated("", audioDuration: 4))
        #expect(!Detector.isTruncated(" . ", audioDuration: 4))
    }

    @Test func prefersOnlyALongerRetry() {
        #expect(Detector.prefersRetry("Ich spreche gerade auf Deutsch.", over: "Ich."))
        #expect(!Detector.prefersRetry("Ich", over: "Ich."))
        #expect(!Detector.prefersRetry("", over: "Ich."))
    }
}
