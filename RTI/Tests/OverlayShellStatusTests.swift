import RTICore
import XCTest

/// Pins what the overlay header says for each session phase: the status
/// word and its tone, the record chip, and the title rule.
final class OverlayShellStatusTests: XCTestCase {
    func test_statusWordAndTonePerPhase() {
        let expected: [(OverlayLivePhase, String, OverlayStatusTone)] = [
            (.idle, "Ready", .ready),
            (.recording, "Recording", .recording),
            (.paused, "Paused", .busy),
            (.finishing, "Saving", .busy),
            (.upgrading, "Improving transcript", .busy),
            (.done, "Session saved", .ready),
        ]
        for (phase, word, tone) in expected {
            let status = OverlayShellStatus(phase: phase)
            XCTAssertEqual(status.word, word, "\(phase)")
            XCTAssertEqual(status.tone, tone, "\(phase)")
        }
    }

    func test_upgradingAndFailedUpgrade_showTheSessionsOwnLine() {
        let progress = OverlayShellStatus(phase: .upgrading, processingStatus: "Transcribing 2 of 3…")
        XCTAssertEqual(progress.word, "Transcribing 2 of 3…")

        let failed = OverlayShellStatus(phase: .done, processingStatus: "Upgrade failed · audio retained")
        XCTAssertEqual(failed.word, "Upgrade failed · audio retained")
        XCTAssertEqual(failed.tone, .busy)

        let saved = OverlayShellStatus(phase: .done, processingStatus: "Session saved")
        XCTAssertEqual(saved.word, "Session saved")
        XCTAssertEqual(saved.tone, .ready)
    }

    func test_recordChip_isFinishWithTheClockWhileLive() {
        for phase in [OverlayLivePhase.recording, .paused] {
            let chip = OverlayShellStatus(phase: phase).recordChip
            XCTAssertEqual(chip.title, "Finish")
            XCTAssertEqual(chip.lead, .liveMark)
            XCTAssertTrue(chip.showsClock)
            XCTAssertEqual(chip.keys, ["⌘", "⇧", "R"])
            XCTAssertTrue(chip.isEnabled)
        }
    }

    func test_recordChip_isRecordWhenACleanStartIsNext() {
        for phase in [OverlayLivePhase.idle, .upgrading, .done] {
            let chip = OverlayShellStatus(phase: phase).recordChip
            XCTAssertEqual(chip.title, "Record", "\(phase)")
            XCTAssertEqual(chip.lead, .recordDot, "\(phase)")
            XCTAssertFalse(chip.showsClock, "\(phase)")
            XCTAssertTrue(chip.isEnabled, "\(phase)")
        }
    }

    func test_recordChip_isDisabledDuringTheSaveFlush() {
        let chip = OverlayShellStatus(phase: .finishing).recordChip
        XCTAssertEqual(chip.lead, .spinner)
        XCTAssertFalse(chip.isEnabled)
        XCTAssertEqual(chip.keys, [])
    }

    func test_noUserFacingTextUsesAnEmDash() {
        for phase in OverlayLivePhase.allCases {
            let status = OverlayShellStatus(phase: phase)
            for text in [status.word, status.recordChip.title, status.recordChip.help, status.recordChip.accessibilityLabel] {
                XCTAssertFalse(text.contains("—"), "\(phase): \(text)")
            }
        }
    }

    func test_titleRule() {
        XCTAssertEqual(OverlayShellStatus.title(calendarTitle: "Quarterly planning sync", projectName: "Northwind", phase: .recording), "Quarterly planning sync")
        XCTAssertEqual(OverlayShellStatus.title(calendarTitle: "  ", projectName: "Northwind", phase: .idle), "Northwind")
        XCTAssertEqual(OverlayShellStatus.title(calendarTitle: nil, projectName: nil, phase: .recording), "Live session")
        XCTAssertEqual(OverlayShellStatus.title(calendarTitle: nil, projectName: nil, phase: .paused), "Live session")
        XCTAssertEqual(OverlayShellStatus.title(calendarTitle: nil, projectName: nil, phase: .idle), "RTI")
        XCTAssertEqual(OverlayShellStatus.title(calendarTitle: nil, projectName: nil, phase: .done), "RTI")
    }
}
