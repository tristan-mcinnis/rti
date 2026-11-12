import XCTest
import RTICore

/// Pins the app's names. The display name is "RTI" (the one project name).
/// The bundle identifier must never change: macOS keys microphone, system
/// audio and screen-recording grants to it, so a rename resets every
/// permission.
final class AppIdentityTests: XCTestCase {
    func testAppearanceFollowsSystemUnlessTheUserSelectedATheme() throws {
        let suite = "rti.appearance.fixture." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(OverlayAppearanceDefaults.defaultAppearanceMode, "system")
        XCTAssertEqual(OverlayAppearanceDefaults.effectiveAppearanceMode(in: defaults), .system)
        defaults.set(false, forKey: OverlayAppearanceDefaults.lightModeKey)
        XCTAssertEqual(OverlayAppearanceDefaults.effectiveAppearanceMode(in: defaults), .dark)
        defaults.set(true, forKey: OverlayAppearanceDefaults.lightModeKey)
        XCTAssertEqual(OverlayAppearanceDefaults.effectiveAppearanceMode(in: defaults), .light)
        for mode in RTIAppearanceMode.allCases {
            defaults.set(mode.rawValue, forKey: OverlayAppearanceDefaults.appearanceModeKey)
            XCTAssertEqual(OverlayAppearanceDefaults.effectiveAppearanceMode(in: defaults), mode)
        }
        defaults.removeObject(forKey: OverlayAppearanceDefaults.lightModeKey)
        defaults.set("obsolete", forKey: OverlayAppearanceDefaults.appearanceModeKey)
        XCTAssertEqual(OverlayAppearanceDefaults.effectiveAppearanceMode(in: defaults), .system)
    }

    private var rtiDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // RTI
    }

    func test_infoPlistUsesTheSignedProductsNameAndIdentifier() throws {
        let url = rtiDirectory.appendingPathComponent("Sources/Info.plist")
        let data = try Data(contentsOf: url)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        XCTAssertEqual(plist["CFBundleName"] as? String, "$(PRODUCT_NAME)")
        XCTAssertEqual(plist["CFBundleDisplayName"] as? String, "$(PRODUCT_NAME)")
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, "$(PRODUCT_BUNDLE_IDENTIFIER)")
    }

    func test_projectSpec_keepsTheBundleIdentifier() throws {
        let spec = try String(
            contentsOf: rtiDirectory.appendingPathComponent("project.yml"),
            encoding: .utf8
        )
        XCTAssertTrue(spec.contains("RTI_APP_NAME: RTI\n"))
        XCTAssertTrue(spec.contains("RTI_APP_ID: com.tristan.rti.personal\n"))
        XCTAssertTrue(spec.contains("PRODUCT_BUNDLE_IDENTIFIER: \"$(RTI_APP_ID)\""))
        XCTAssertTrue(spec.contains("PRODUCT_NAME: \"$(RTI_APP_NAME)\""))
    }
}
