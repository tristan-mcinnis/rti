import Foundation
import RTICore
import XCTest

final class SessionAudioTimelineTests: XCTestCase {
    func testBothLegsRemainAlignedWhenSeeking() {
        let legs: [SessionAudioTimeline.Leg] = [.init(offset: 0, duration: 10), .init(offset: 2, duration: 12)]
        XCTAssertEqual(SessionAudioTimeline.duration(of: legs), 14)
        let early = SessionAudioTimeline.starts(at: 1, legs: legs)
        XCTAssertEqual(early.map(\.index), [0, 1])
        XCTAssertEqual(early.map(\.sourceTime), [1, 0])
        XCTAssertEqual(early.map(\.delay), [0, 1])
        let later = SessionAudioTimeline.starts(at: 4, legs: legs)
        XCTAssertEqual(later.map(\.sourceTime), [4, 2])
        XCTAssertEqual(later.map(\.delay), [0, 0])
    }

    func testFinishedLegStopsWhileLongerLegContinues() {
        let legs: [SessionAudioTimeline.Leg] = [.init(offset: 0, duration: 5), .init(offset: 2, duration: 8)]
        XCTAssertEqual(SessionAudioTimeline.starts(at: 7, legs: legs).map(\.index), [1])
        XCTAssertTrue(SessionAudioTimeline.starts(at: 10, legs: legs).isEmpty)
    }

    func testEarlierSystemCaptureKeepsItsLead() {
        let legs: [SessionAudioTimeline.Leg] = [.init(offset: 0, duration: 10), .init(offset: -1, duration: 10)]
        let plan = SessionAudioTimeline.starts(at: 0, legs: legs)
        XCTAssertEqual(plan.map(\.delay), [1, 0])
        XCTAssertEqual(SessionAudioTimeline.duration(of: legs), 11)
    }

    func testTrashPolicyAllowsOnlyDirectTimestampedRTIArchiveFolders() {
        let root = URL(fileURLWithPath: "/tmp/rti-fixture/sessions", isDirectory: true)
        XCTAssertTrue(SessionArchiveActionRules.canTrash(sessionDirectory: root.appendingPathComponent("2026-09-16 123456"), archiveRoot: root))
        for invalid in [root, root.appendingPathComponent("notes.md"), root.appendingPathComponent("2026-09-16 123456/nested"), root.appendingPathComponent("../meetings/2026-09-16 123456")] {
            XCTAssertFalse(SessionArchiveActionRules.canTrash(sessionDirectory: invalid, archiveRoot: root))
        }
    }
}
