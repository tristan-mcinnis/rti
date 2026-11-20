import RTICore
import XCTest

/// 2026-11-20: the after-call loop. Room meetings, silent legs, which calls
/// upgrade, the retry timer and the call type an event suggests.
final class AfterCallTests: XCTestCase {
    func testWhatRunsAfterACall() {
        XCTAssertEqual(AfterCallPlan.decide(callType: .client, audioSeconds: 3600), .upgrade)
        XCTAssertEqual(AfterCallPlan.decide(callType: .research, audioSeconds: 600), .upgrade)
        XCTAssertEqual(AfterCallPlan.decide(callType: .personal, audioSeconds: 1800), .liveNote)
        XCTAssertEqual(AfterCallPlan.decide(callType: .client, audioSeconds: 90), .nothing)
        XCTAssertEqual(AfterCallPlan.decide(callType: .personal, audioSeconds: 30), .nothing)
        XCTAssertNil(AfterCallPlan.upgrade.statusLine)
        XCTAssertNotNil(AfterCallPlan.liveNote.statusLine)
    }

    private func metadata(seconds: Int, gaps: [CaptureGap], room: Bool = false) -> SessionArchiveMetadata {
        var m = SessionArchiveMetadata(sessionId: "s", systemAudioStartOffsetMs: 8000, micAudioFile: "audio-mic.wav",
                                       systemAudioFile: "audio-system.wav", mode: "Client call", workstream: nil,
                                       durationSeconds: seconds)
        m.captureGaps = gaps
        m.speakerPolicy = SessionSpeakerPolicy(roomLabels: room)
        return m
    }

    func testAMeetingInTheRoom() {
        // The whole meeting with no computer audio, as on 2026-11-19.
        XCTAssertTrue(metadata(seconds: 4031, gaps: [.init(leg: .system, reason: .captureFailed, startMs: 8442, endMs: 4_031_099)]).isInRoom)
        // An open gap runs to the end of the call.
        XCTAssertTrue(metadata(seconds: 600, gaps: [.init(leg: .system, reason: .noAudio, startMs: 5000, endMs: nil)]).isInRoom)
        // A short outage on a real call is not a room meeting.
        XCTAssertFalse(metadata(seconds: 1593, gaps: [.init(leg: .system, reason: .captureFailed, startMs: 38860, endMs: 75647)]).isInRoom)
        // Mic gaps never count.
        XCTAssertFalse(metadata(seconds: 600, gaps: [.init(leg: .mic, reason: .noAudio, startMs: 0, endMs: 600_000)]).isInRoom)
        XCTAssertTrue(metadata(seconds: 600, gaps: [], room: true).isInRoom)
        XCTAssertFalse(metadata(seconds: 30, gaps: [.init(leg: .system, reason: .noAudio, startMs: 0, endMs: 30000)]).isInRoom)
    }

    func testTheRoomChoiceIsStoredAndOldFilesLoad() throws {
        let data = try JSONEncoder().encode(SessionSpeakerPolicy(roomLabels: true))
        XCTAssertEqual(try JSONDecoder().decode(SessionSpeakerPolicy.self, from: data).roomLabels, true)
        let old = try JSONDecoder().decode(SessionSpeakerPolicy.self, from: Data(#"{"labelsEnabled":true}"#.utf8))
        XCTAssertFalse(old.roomLabels)
        XCTAssertFalse(old.requestsLabels(system: false))
        XCTAssertTrue(old.requestsLabels(system: true))
        XCTAssertTrue(SessionSpeakerPolicy(roomLabels: true).requestsLabels(system: false))
        XCTAssertFalse(SessionSpeakerPolicy(labelsEnabled: false, roomLabels: true).requestsLabels(system: false))
    }

    func testRoomSpeakersGetTheirOwnLabels() throws {
        let data = Data(#"{"tokens":[{"text":"我们先看","speaker":"1","start_ms":0,"end_ms":400},{"text":"报告。","speaker":"1","start_ms":400,"end_ms":800},{"text":"好的。","speaker":"2","start_ms":900,"end_ms":1200}]}"#.utf8)
        let room = try SonioxAsyncTurns.segments(data: data, system: false, policy: .init(roomLabels: true), offsetMs: 0)
        XCTAssertEqual(room.map(\.speaker), ["Room speaker 1", "Room speaker 2"])
        let call = try SonioxAsyncTurns.segments(data: data, system: false, policy: .init(), offsetMs: 0)
        XCTAssertEqual(Set(call.map(\.speaker)), ["Me"])
    }

    func testAnEmptyComputerLegIsNotSent() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["audio-mic.wav", "audio-system.wav"] {
            try Self.wav(seconds: 1).write(to: dir.appendingPathComponent(name))
        }
        func write(_ m: SessionArchiveMetadata) throws {
            try JSONEncoder().encode(m).write(to: dir.appendingPathComponent("session.json"))
        }
        try write(metadata(seconds: 600, gaps: []))
        XCTAssertEqual(TranscriptUpgradeAudioDiscovery.upgradeInputs(in: dir).count, 2)
        try write(metadata(seconds: 600, gaps: [.init(leg: .system, reason: .captureFailed, startMs: 0, endMs: 600_000)]))
        XCTAssertEqual(TranscriptUpgradeAudioDiscovery.upgradeInputs(in: dir).map(\.url.lastPathComponent), ["audio-mic.wav"])
        XCTAssertEqual(TranscriptUpgradeAudioDiscovery.inputs(in: dir).count, 2)
    }

    func testAQueuedUpgradeIsRetriedOnATimer() {
        XCTAssertEqual(PendingUpgradeRetry.delay(afterAttempt: 0), .seconds(600))
        XCTAssertEqual(PendingUpgradeRetry.delay(afterAttempt: 1), .seconds(1800))
        XCTAssertEqual(PendingUpgradeRetry.delay(afterAttempt: 2), .seconds(3600))
        XCTAssertEqual(PendingUpgradeRetry.delay(afterAttempt: 9), .seconds(3600))
    }

    private let me = CalendarMeeting.Attendee(name: "Me", email: "me@studio.example", isCurrentUser: true)
    private let colleague = CalendarMeeting.Attendee(name: "Mira", email: "mira@studio.example")
    private let client = CalendarMeeting.Attendee(name: "Vic", email: "vic@acme.example")

    func testTheCallTypeAnEventSuggests() {
        // A catch-up with a colleague, left on Research from the call before.
        XCTAssertEqual(CallTypeSuggestion.suggest(title: "Lumo China Diagnosis - Catch up with Mira", attendees: [me, colleague],
                                                  current: .research, hasGuide: false), .internal)
        // A client meeting about the groups is not a group.
        XCTAssertEqual(CallTypeSuggestion.suggest(title: "Lumo Focus Group follow up discussion", attendees: [me, colleague, client],
                                                  current: .research, hasGuide: false), .client)
        XCTAssertEqual(CallTypeSuggestion.suggest(title: "Lumo FGD 2 (Shanghai)", attendees: [me, client],
                                                  current: .client, hasGuide: false), .research)
        XCTAssertEqual(CallTypeSuggestion.suggest(title: "IDI respondent 4", attendees: [], current: .client, hasGuide: false), .research)
        // Already right: no change.
        XCTAssertNil(CallTypeSuggestion.suggest(title: "Weekly sync", attendees: [me, client], current: .client, hasGuide: false))
        // A picked guide means research.
        XCTAssertEqual(CallTypeSuggestion.suggest(title: "Weekly sync", attendees: [me, client], current: .client, hasGuide: true), .research)
        // Personal stays personal; an event with nobody on it keeps the type, unless it is a groundless Research.
        XCTAssertNil(CallTypeSuggestion.suggest(title: "Dinner plans", attendees: [me, client], current: .personal, hasGuide: false))
        XCTAssertNil(CallTypeSuggestion.suggest(title: "Prep", attendees: [], current: .internal, hasGuide: false))
        XCTAssertEqual(CallTypeSuggestion.suggest(title: "Prep", attendees: [], current: .research, hasGuide: false), .client)
    }

    /// A tiny valid 16 kHz mono PCM WAV.
    private static func wav(seconds: Int) -> Data {
        let samples = 16000 * seconds
        var d = Data()
        func u32(_ v: UInt32) {
            withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
        }
        func u16(_ v: UInt16) {
            withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
        }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + samples * 2)); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(16000); u32(32000); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(samples * 2)); d.append(Data(count: samples * 2))
        return d
    }
}
