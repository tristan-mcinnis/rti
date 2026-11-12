import RTICore
import XCTest

/// Live reading rules from the 2026-11-12 Soniox trial: no live speaker
/// guesses by default, breaks only at sentence ends, pauses measured between
/// words. Token times below are the shapes Soniox sent in that trial.
final class LiveTranscriptRealtimeReadingTests: XCTestCase {
    private func entry(_ tokens: [(String, Int, Int)], speaker: String = "remote") -> LiveEntry {
        let timed = tokens.map { LiveEntry.TimedToken(text: $0.0, startMs: $0.1, endMs: $0.2) }
        return LiveEntry(speakerId: speaker, text: timed.map(\.text).joined(), startMs: timed[0].startMs, confidence: 1,
                         translationStatus: "none", language: "zh", sourceLanguage: nil,
                         textOrigin: .providerTokens, streamID: UUID(), tokens: timed)
    }

    private func paragraphs(_ entries: [LiveEntry]) -> [String] {
        var projection = LiveTranscriptPresentation.Projection()
        projection.updateFinals(entries)
        let turns = LiveTranscriptPresentation.turns(projection.updateInterims([]))
        XCTAssertEqual(turns.count, 1)
        return turns.flatMap(\.paragraphs).map { $0.map(\.text).joined().trimmingCharacters(in: .whitespaces) }
    }

    private func chars(_ text: String, from start: Int, step: Int = 60) -> [(String, Int, Int)] {
        text.enumerated().map { (String($0.element), start + $0.offset * step, start + $0.offset * step + 50) }
    }

    func test_thinkingPauseStaysInsideTheSentence_andAPauseAfterASentenceStartsAParagraph() {
        // 1.2 s pause after 产品 (mid-sentence); the 。 and the space are timed
        // inside the next silence, and 你 follows 0.96 s after the last word.
        let tokens = chars("我觉得这个产品", from: 60)
            + chars("还挺好的", from: 2220)
            + [("。", 3360, 3420), (" ", 3840, 3900)]
            + chars("你们觉得呢", from: 3960) + [("？", 4560, 4560)]
        XCTAssertEqual(paragraphs([entry(tokens)]), ["我觉得这个产品还挺好的。", "你们觉得呢？"])
    }

    func test_aMarkAfterASilenceNeverStartsALineOfItsOwn() {
        let tokens = [("Balance", 0, 400), (".", 1600, 1660), (" OK", 1700, 1900), (".", 1900, 1950)]

        XCTAssertEqual(paragraphs([entry(tokens)]), ["Balance.", "OK."])
    }

    func test_crosstalkWithNoSilenceBreaksAtTheFirstSentenceEndPastTheSoftLimit() {
        let a = String(repeating: "啊", count: 49) + "。"
        let b = String(repeating: "哦", count: 39) + "。"
        let tokens = chars(a + b + "好。", from: 0, step: 50)

        XCTAssertEqual(paragraphs([entry(tokens)]), [a + b, "好。"])
    }

    func test_liveSpeakerGuessesAreOffByDefault_andTheFileTranscriptKeepsLabels() throws {
        let policy = SessionSpeakerPolicy()
        XCTAssertFalse(policy.liveLabelsEnabled)
        XCTAssertTrue(policy.labelsEnabled)

        let archived = try JSONDecoder().decode(SessionSpeakerPolicy.self,
                                                from: Data(#"{"labelsEnabled":true,"expectedCount":7}"#.utf8))
        XCTAssertEqual(archived, SessionSpeakerPolicy(labelsEnabled: true, liveLabelsEnabled: false, expectedCount: 7))

        let roundTrip = SessionSpeakerPolicy(labelsEnabled: false, liveLabelsEnabled: true)
        XCTAssertEqual(try JSONDecoder().decode(SessionSpeakerPolicy.self, from: JSONEncoder().encode(roundTrip)), roundTrip)
    }

    func test_withLiveLabelsOffTheSystemLegIsOneThemSpeaker() {
        let pipeline = TranscriptPipeline()
        pipeline.systemSpeakerLabelsEnabled = false
        let words = [#"{"text":"还有吗？","speaker":"1","start_ms":0,"end_ms":300,"is_final":true}"#,
                     #"{"text":"没有了。","speaker":"2","start_ms":900,"end_ms":1200,"is_final":true}"#]
            .map { try! JSONDecoder().decode(SonioxWord.self, from: Data($0.utf8)) }

        pipeline.process(words: words, channel: "system")

        XCTAssertEqual(Set(pipeline.liveEntries.map(\.speakerId)), ["remote"])
    }
}
