import XCTest

/// Pins the app's names. The display name is "RTI" (the one project name).
/// The bundle identifier must never change: macOS keys microphone, system
/// audio and screen-recording grants to it, so a rename resets every
/// permission.
final class AppIdentityTests: XCTestCase {
    private var rtiDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // RTI
    }

    func test_infoPlist_namesTheAppRTI() throws {
        let url = rtiDirectory.appendingPathComponent("Sources/Info.plist")
        let data = try Data(contentsOf: url)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        XCTAssertEqual(plist["CFBundleName"] as? String, "RTI")
        XCTAssertEqual(plist["CFBundleDisplayName"] as? String, "RTI")
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, "$(PRODUCT_BUNDLE_IDENTIFIER)")
    }

    func test_projectSpec_keepsTheBundleIdentifier() throws {
        let spec = try String(
            contentsOf: rtiDirectory.appendingPathComponent("project.yml"),
            encoding: .utf8
        )
        XCTAssertTrue(spec.contains("PRODUCT_BUNDLE_IDENTIFIER: com.tristan.rti.personal\n"))
    }
}
