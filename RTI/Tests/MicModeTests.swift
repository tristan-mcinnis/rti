import RTICore
import XCTest

final class MicModeTests: XCTestCase {
    func testInCallMuteDoesNotCarryIntoNextCall() {
        var mic = MicControl()
        mic.reduce(.sessionStarted)
        mic.reduce(.toggleMute)
        XCTAssertTrue(mic.micMuted)
        mic.reduce(.sessionStopped)
        mic.reduce(.sessionStarted)
        XCTAssertFalse(mic.micMuted)
        XCTAssertEqual(mic.mode, .open)
    }

    func testListeningOnlyPresetAppliesToFirstStartOnly() {
        var mic = MicControl()
        mic.reduce(.setPreset(.listeningOnly))
        mic.reduce(.sessionStarted)
        XCTAssertTrue(mic.micMuted)
        XCTAssertTrue(mic.isListeningOnly)
        mic.reduce(.sessionStopped)
        XCTAssertEqual(mic.preset, .speaking)
        mic.reduce(.sessionStarted)
        XCTAssertFalse(mic.micMuted)
        XCTAssertFalse(mic.isListeningOnly)
    }

    func testToggleMuteNeverChangesPreset() {
        var mic = MicControl()
        mic.reduce(.setPreset(.listeningOnly))
        mic.reduce(.sessionStarted)
        for _ in 0 ..< 3 {
            mic.reduce(.toggleMute)
            XCTAssertEqual(mic.preset, .listeningOnly)
        }
        var speaking = MicControl()
        speaking.reduce(.toggleMute)
        XCTAssertEqual(speaking.preset, .speaking)
        speaking.reduce(.sessionStarted)
        speaking.reduce(.toggleMute)
        XCTAssertEqual(speaking.preset, .speaking)
    }

    func testToggleMuteFromListeningOnlyOpensThenMutesInCall() {
        let live = MicControl().reduced(.setPreset(.listeningOnly)).reduced(.sessionStarted)
        let opened = live.reduced(.toggleMute)
        XCTAssertEqual(opened.mode, .open)
        XCTAssertEqual(opened.reduced(.toggleMute).mode, .mutedInCall)
    }

    func testPlainMuteShowsBannerAndListeningOnlyDoesNot() {
        let muted = MicControl().reduced(.sessionStarted).reduced(.toggleMute)
        XCTAssertTrue(muted.bannerVisible)
        XCTAssertFalse(muted.isListeningOnly)
        let listening = MicControl().reduced(.setPreset(.listeningOnly)).reduced(.sessionStarted)
        XCTAssertTrue(listening.micMuted)
        XCTAssertFalse(listening.bannerVisible)
    }

    func testPresetCannotChangeDuringCall() {
        var mic = MicControl().reduced(.sessionStarted)
        mic.reduce(.setPreset(.listeningOnly))
        XCTAssertEqual(mic.preset, .speaking)
        XCTAssertFalse(mic.micMuted)
    }

    func testToggleMuteOutsideCallIsIgnored() {
        let idle = MicControl().reduced(.toggleMute)
        XCTAssertFalse(idle.micMuted)
        XCTAssertEqual(idle.reduced(.sessionStarted).mode, .open)
    }

    func testMuteIsAvailableOnlyDuringALiveCall() {
        var mic = MicControl()
        XCTAssertFalse(mic.canToggleMute)
        mic.reduce(.sessionStarted)
        XCTAssertTrue(mic.canToggleMute)
        mic.reduce(.sessionFinishing)
        XCTAssertFalse(mic.canToggleMute)
        mic.reduce(.sessionStopped)
        XCTAssertFalse(mic.canToggleMute)
        XCTAssertEqual(MicControl.muteUnavailableHelp,
                       "Mute works during a call. For an observed session, turn on Listening only in Prepare.")
    }

    func testStopWithoutALiveCallKeepsThePreset() {
        // A start cancelled at the mic prompt never went live.
        let cancelled = MicControl().reduced(.setPreset(.listeningOnly)).reduced(.sessionStopped)
        XCTAssertEqual(cancelled.preset, .listeningOnly)
        XCTAssertTrue(cancelled.reduced(.sessionStarted).isListeningOnly)
    }

    func testFinishingFreesThePresetAndStopStillResetsIt() {
        var mic = MicControl().reduced(.setPreset(.listeningOnly)).reduced(.sessionStarted)
        mic.reduce(.sessionFinishing)
        XCTAssertFalse(mic.isLive)
        XCTAssertTrue(mic.micMuted, "Trailing audio stays muted until the call is over")
        mic.reduce(.sessionStopped)
        XCTAssertEqual(mic.preset, .speaking, "The one-call preset ends with the call")
        XCTAssertFalse(mic.micMuted)
    }

    func testPresetChosenWhileFinishingSurvivesTheStop() {
        var mic = MicControl().reduced(.sessionStarted)
        mic.reduce(.sessionFinishing)
        mic.reduce(.setPreset(.listeningOnly))
        XCTAssertEqual(mic.preset, .listeningOnly, "The Prepare switch takes input while finishing")
        mic.reduce(.sessionStopped)
        XCTAssertEqual(mic.preset, .listeningOnly, "A choice for the next call is kept")
    }
}
