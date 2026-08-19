import XCTest
@testable import RTI

final class AudioInputDeviceTests: XCTestCase {
    func testIsVirtualNameMatchesDenylist() {
        XCTAssertTrue(AudioInputDeviceStore.isVirtualName("BlackHole 2ch"))
        XCTAssertTrue(AudioInputDeviceStore.isVirtualName("blackhole 16ch"))
        XCTAssertTrue(AudioInputDeviceStore.isVirtualName("Loopback Audio"))
        XCTAssertTrue(AudioInputDeviceStore.isVirtualName("Soundflower (2ch)"))
        XCTAssertTrue(AudioInputDeviceStore.isVirtualName("VB-Cable"))
        XCTAssertTrue(AudioInputDeviceStore.isVirtualName("VB-Audio Virtual Cable"))
        XCTAssertTrue(AudioInputDeviceStore.isVirtualName("My Aggregate Device"))
        XCTAssertTrue(AudioInputDeviceStore.isVirtualName("Multi-Output Device"))
        XCTAssertTrue(AudioInputDeviceStore.isVirtualName("ZoomAudioDevice"))
        XCTAssertTrue(AudioInputDeviceStore.isVirtualName("Teams Audio"))
        XCTAssertTrue(AudioInputDeviceStore.isVirtualName("Krisp Microphone"))
    }

    func testIsVirtualNameDoesNotFlagRealMics() {
        XCTAssertFalse(AudioInputDeviceStore.isVirtualName("MacBook Pro Microphone"))
        XCTAssertFalse(AudioInputDeviceStore.isVirtualName("External Microphone"))
        XCTAssertFalse(AudioInputDeviceStore.isVirtualName("AirPods Pro"))
        XCTAssertFalse(AudioInputDeviceStore.isVirtualName("Shure MV7"))
    }

    func testSystemDefaultSentinelIsStable() {
        // Guards against accidental drift in the sentinel string other code
        // (GeneralTab, OverlayMicControl) compares against.
        XCTAssertEqual(AudioInputDevice.systemDefaultUID, "__system_default__")
    }
}
