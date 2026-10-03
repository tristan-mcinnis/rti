import XCTest

/// The unattended `/meeting` run is opt-in and safe by default.
final class MeetingProcessorConfigTests: XCTestCase {
    func testProcessorIsOffByDefault() {
        XCTAssertFalse(MeetingProcessorConfig.isEnabled(config: [:]))
    }

    func testProcessorIsOffForANonBooleanValue() {
        XCTAssertFalse(MeetingProcessorConfig.isEnabled(config: ["auto_process": "true"]))
    }

    func testProcessorTurnsOnOnlyWhenAutoProcessIsTrue() {
        XCTAssertTrue(MeetingProcessorConfig.isEnabled(config: ["auto_process": true]))
        XCTAssertFalse(MeetingProcessorConfig.isEnabled(config: ["auto_process": false]))
    }

    func testPermissionModeDefaultsToAcceptEdits() {
        XCTAssertEqual(
            MeetingProcessorConfig.permissionArguments(config: [:]),
            ["--permission-mode", "acceptEdits"]
        )
        XCTAssertEqual(
            MeetingProcessorConfig.permissionArguments(config: ["auto_process": true]),
            ["--permission-mode", "acceptEdits"]
        )
    }

    func testSkippingPermissionsNeedsAnExplicitYolo() {
        XCTAssertEqual(
            MeetingProcessorConfig.permissionArguments(config: ["auto_process_yolo": true]),
            ["--dangerously-skip-permissions"]
        )
        XCTAssertEqual(
            MeetingProcessorConfig.permissionArguments(config: ["auto_process_yolo": false]),
            ["--permission-mode", "acceptEdits"]
        )
    }
}
