import RTICore
import XCTest

/// Pins when the welcome window's Get Started turns on and what its
/// footnote says is missing.
final class OnboardingChecklistTests: XCTestCase {
    func test_keysAndMicrophone_makeItReady_screenIsOptional() {
        let checklist = OnboardingChecklist(keysSaved: true, microphone: .granted, screenRecording: .notAsked)
        XCTAssertTrue(checklist.isReady)
        XCTAssertEqual(checklist.footnote, "All set. ⌘⇧R starts your first recording.")
    }

    func test_nothingDone_namesBothSteps() {
        let checklist = OnboardingChecklist(keysSaved: false, microphone: .notAsked, screenRecording: .notAsked)
        XCTAssertFalse(checklist.isReady)
        XCTAssertEqual(checklist.footnote, "Save both API keys and allow the microphone to finish.")
    }

    func test_keysMissing_withMicrophoneGranted() {
        let checklist = OnboardingChecklist(keysSaved: false, microphone: .granted, screenRecording: .granted)
        XCTAssertFalse(checklist.isReady)
        XCTAssertEqual(checklist.footnote, "Save both API keys to finish.")
    }

    func test_microphoneDenied_pointsToSystemSettings() {
        let checklist = OnboardingChecklist(keysSaved: true, microphone: .denied, screenRecording: .granted)
        XCTAssertFalse(checklist.isReady)
        XCTAssertEqual(checklist.footnote, "Allow the microphone in System Settings to finish.")
    }

    func test_microphoneNotAsked_withKeysSaved() {
        let checklist = OnboardingChecklist(keysSaved: true, microphone: .notAsked, screenRecording: .denied)
        XCTAssertFalse(checklist.isReady)
        XCTAssertEqual(checklist.footnote, "Allow the microphone to finish.")
    }

    func test_noFootnoteUsesAnEmDash() {
        for keys in [true, false] {
            for mic in [OnboardingChecklist.Access.granted, .denied, .notAsked] {
                let line = OnboardingChecklist(keysSaved: keys, microphone: mic, screenRecording: .notAsked).footnote
                XCTAssertFalse(line.contains("\u{2014}"), line)
            }
        }
    }
}
