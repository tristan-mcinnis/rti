import Foundation
@testable import RTICore
import XCTest

/// AUD-4: the record of stretches a leg did not record. Pure values only.
final class CaptureGapLogTests: XCTestCase {
    func testOverlappingReportsOfOneStretchMergePerLeg() {
        var log = CaptureGapLog()
        // The watchdog sees the mic outage, then the writer fills the same
        // stretch with silence when the mic returns.
        log.begin(.mic, .noAudio, atMs: 60000)
        log.end(.mic, .noAudio, atMs: 90000)
        log.add(.mic, .noAudio, startMs: 59500, endMs: 90400)
        log.add(.system, .noAudio, startMs: 1000, endMs: 121_000)
        XCTAssertEqual(log.gaps, [
            CaptureGap(leg: .system, reason: .noAudio, startMs: 1000, endMs: 121_000),
            CaptureGap(leg: .mic, reason: .noAudio, startMs: 59500, endMs: 90400),
        ])
    }

    func testOpenGapStaysOpenUntilTheRecordingStops() {
        var log = CaptureGapLog()
        log.begin(.system, .captureFailed, atMs: 5000)
        log.begin(.system, .captureFailed, atMs: 9000)
        XCTAssertEqual(log.gaps, [CaptureGap(leg: .system, reason: .captureFailed, startMs: 5000, endMs: nil)])
        XCTAssertTrue(CaptureGapLog.describe(log.gaps[0]).contains("still missing when this was saved"))
        log.closeAll(atMs: 65000)
        XCTAssertEqual(log.gaps.first?.endMs, 65000)
        XCTAssertEqual(CaptureGapLog.describe(log.gaps[0]),
                       "The other side (system audio): 00:00:05 to 00:01:05 (1 min). System audio capture stopped or carried no sound.")
    }

    func testSeparateStretchesStaySeparate() {
        var log = CaptureGapLog()
        log.add(.mic, .silentInput, startMs: 0, endMs: 10000)
        log.add(.mic, .noAudio, startMs: 20000, endMs: 30000)
        XCTAssertEqual(log.gaps.count, 2)
    }

    func testMarkdownAndAnnotation() {
        let gaps = [CaptureGap(leg: .mic, reason: .silentInput, startMs: 3_600_000, endMs: 3_725_000)]
        let block = CaptureGapLog.markdown(gaps)
        XCTAssertEqual(block.count, 2)
        XCTAssertTrue(block[1].contains("Your microphone: 01:00:00 to 01:02:05 (2 min 5 s)"))
        XCTAssertTrue(CaptureGapLog.markdown([]).isEmpty)

        let upgraded = "# Transcript\n\n`0:01` **Remote speaker 1:** Invented line."
        let annotated = CaptureGapLog.annotate(upgraded, gaps: gaps)
        XCTAssertTrue(annotated.hasPrefix("# Transcript\n\n> **Recording gaps.**"))
        XCTAssertTrue(annotated.contains("Invented line."))
        XCTAssertEqual(CaptureGapLog.annotate(annotated, gaps: gaps), annotated, "Never added twice")
        XCTAssertEqual(CaptureGapLog.annotate(upgraded, gaps: []), upgraded)
    }

    func testMetadataKeepsGapsAndOldFilesStillLoad() throws {
        let old = Data(#"{"sessionId":"s1","systemAudioStartOffsetMs":8000}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(SessionArchiveMetadata.self, from: old).captureGaps)
        var metadata = try JSONDecoder().decode(SessionArchiveMetadata.self, from: old)
        metadata.captureGaps = [CaptureGap(leg: .system, reason: .noAudio, startMs: 9000, endMs: 129_000)]
        let data = try JSONEncoder().encode(metadata)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"capture_gaps\""))
        XCTAssertEqual(try JSONDecoder().decode(SessionArchiveMetadata.self, from: data).captureGaps, metadata.captureGaps)
    }
}
