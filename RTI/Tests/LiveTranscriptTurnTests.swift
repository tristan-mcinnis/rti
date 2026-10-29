import RTICore
import XCTest

final class LiveTranscriptTurnTests: XCTestCase {
    private func timed(_ script: String, at startMs: Int) -> [LiveEntry.TimedToken] {
        EchoMeetingFixture.tokens(script, speaker: 0, at: startMs).map {
            LiveEntry.TimedToken(text: $0.text, startMs: $0.startMs, endMs: $0.endMs)
        }
    }

    private func source(_ speakerId: String, _ script: String, at startMs: Int) -> EchoFilter.Source {
        EchoFilter.Source(speakerId: speakerId, tokens: timed(script, at: startMs))
    }

    private func entry(_ speakerId: String, _ script: String, at startMs: Int, stream: UUID = UUID()) -> LiveEntry {
        let tokens = timed(script, at: startMs)
        return LiveEntry(speakerId: speakerId, text: tokens.map(\.text).joined(), startMs: startMs, confidence: 1,
                         translationStatus: "none", language: nil, sourceLanguage: nil,
                         textOrigin: .providerTokens, streamID: stream, tokens: tokens)
    }

    private func turns(_ entries: [LiveEntry], interims: [LiveTranscriptPresentation.InterimSegment] = [])
        -> [LiveTranscriptPresentation.Turn] {
        var projection = LiveTranscriptPresentation.Projection()
        projection.updateFinals(entries)
        return LiveTranscriptPresentation.turns(projection.updateInterims(interims))
    }

    // MARK: - Echo

    func test_echoRunOnMicIsDropped_evenWhenAWordIsMisheardAndBatchesDiffer() {
        let system = [source("remote_1", "We could run the first workshop in Hang|zhou on the fourth", at: 10_000)]
        let mic = [
            source("room_1", "We could run the first", at: 10_150),
            source("room_1", "work|shop in Hang|zhou on the forth", at: 11_400),
        ]

        let echo = EchoFilter.echoTokens(mic: mic, system: system)

        XCTAssertEqual(echo[0], Set(0..<5))
        XCTAssertEqual(echo[1], Set(0..<8))
    }

    func test_realSpeechSharingCommonWordsIsKept() {
        let system = [source("remote_1", "the first workshop is fine", at: 10_000)]
        let mic = [source("self", "I think the first option wins", at: 10_100)]

        XCTAssertEqual(EchoFilter.echoTokens(mic: mic, system: system), [[]])
    }

    func test_repeatingAPhraseLaterIsNotEcho() {
        let system = [source("remote_1", "book the fourth", at: 10_000)]
        let mic = [source("self", "book the fourth", at: 14_000)]

        XCTAssertEqual(EchoFilter.echoTokens(mic: mic, system: system), [[]])
    }

    func test_singleWordEchoIsDropped_butTheMicWearersOwnRunIsNot() {
        let system = [source("remote_1", "Yeah.", at: 22_000)]
        let mic = [source("self", "Fine by me.", at: 20_000), source("room_1", "Yeah.", at: 22_100)]

        XCTAssertEqual(EchoFilter.echoTokens(mic: mic, system: system), [[], [0]])
    }

    func test_cjkTokensAreComparedPerCharacter() {
        let tokens = ["我们", "在", "杭州"].enumerated().map {
            LiveEntry.TimedToken(text: $0.element, startMs: 1_000 + $0.offset * 200, endMs: 1_150 + $0.offset * 200)
        }
        let echoTokens = tokens.map { LiveEntry.TimedToken(text: $0.text, startMs: $0.startMs + 120, endMs: $0.endMs + 120) }

        let echo = EchoFilter.echoTokens(mic: [.init(speakerId: "room_1", tokens: echoTokens)],
                                         system: [.init(speakerId: "remote_1", tokens: tokens)])

        XCTAssertEqual(echo, [Set(0..<3)])
    }

    // MARK: - Pipeline

    func test_echoMeetingFixtureHasNoMicEchoInFinalsOrInterims() {
        let pipeline = TranscriptPipeline()
        EchoMeetingFixture.replay(into: pipeline)

        XCTAssertEqual(Set(pipeline.liveEntries.map(\.speakerId)), ["remote_1", "self"])
        XCTAssertEqual(pipeline.interimSegments.map(\.speakerId), ["remote_1"])
    }

    func test_echoMeetingFixtureReadsAsThreeTurnsWithWholeWordsAndNoRepeats() {
        let pipeline = TranscriptPipeline()
        EchoMeetingFixture.replay(into: pipeline)

        let result = turns(pipeline.liveEntries, interims: pipeline.interimSegments)

        XCTAssertEqual(result.map(\.speakerLabel), ["Speaker 1", "You", "Speaker 1"])
        XCTAssertEqual(result[0].text.trimmingCharacters(in: .whitespaces),
                       "We could run the first workshop in Hangzhou on the fourth, then fly to Chengdu after lunch."
                           + " That leaves one slot for the client review.")
        XCTAssertEqual(result[1].text.trimmingCharacters(in: .whitespaces), EchoMeetingFixture.selfLine)
        XCTAssertEqual(result[2].text.trimmingCharacters(in: .whitespaces), "Yeah. " + EchoMeetingFixture.interimLine)
        XCTAssertTrue(result[2].hasPending)
        let all = result.map(\.text).joined(separator: " ")
        XCTAssertFalse(all.contains("Changdo"))
        XCTAssertEqual(all.components(separatedBy: "Yeah.").count - 1, 1)
        XCTAssertEqual(all.components(separatedBy: "putting the fourth").count - 1, 1)
    }

    // MARK: - Turns

    func test_consecutiveRowsOfOneSpeakerShareOneTurn() {
        let stream = UUID()
        let result = turns([
            entry("remote_1", "on the twelfth", at: 1_000, stream: stream),
            entry("remote_1", "and then the thirteenth", at: 4_000, stream: stream),
            entry("self", "fine", at: 6_000),
            entry("remote_1", "great", at: 8_000, stream: stream),
        ])

        XCTAssertEqual(result.map(\.speakerLabel), ["Speaker 1", "You", "Speaker 1"])
        XCTAssertEqual(result[0].text.trimmingCharacters(in: .whitespaces), "on the twelfth and then the thirteenth")
        XCTAssertEqual(result[0].startMs, 1_000)
        XCTAssertEqual(result[0].id, result[0].rows[0].id)
    }

    func test_longSilenceStartsANewTurnForTheSameSpeaker() {
        let stream = UUID()
        let result = turns([
            entry("remote_1", "first point", at: 1_000, stream: stream),
            entry("remote_1", "much later", at: 1_000 + LiveTranscriptPresentation.turnGapMs + 2_000, stream: stream),
        ])

        XCTAssertEqual(result.count, 2)
    }

    func test_notesNeverJoinATurn() {
        let note = LiveEntry(speakerId: "note", text: "check dates", startMs: 2_000, confidence: 1,
                             translationStatus: "none", language: nil, sourceLanguage: nil)
        let result = turns([note, LiveEntry(speakerId: "note", text: "and venue", startMs: 2_500, confidence: 1,
                                            translationStatus: "none", language: nil, sourceLanguage: nil)])

        XCTAssertEqual(result.count, 2)
    }
}
