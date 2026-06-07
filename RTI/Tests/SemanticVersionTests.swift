import RTICore
import XCTest

/// Pins SemanticVersion parsing + ordering — the logic the update checker uses
/// to decide whether a GitHub release is newer than the running build.
final class SemanticVersionTests: XCTestCase {
    private func v(_ s: String) -> SemanticVersion {
        guard let parsed = SemanticVersion(s) else {
            fatalError("expected \(s) to parse")
        }
        return parsed
    }

    func test_parsesCoreAndStripsVPrefix() {
        let a = v("v0.2.0")
        XCTAssertEqual([a.major, a.minor, a.patch], [0, 2, 0])
        XCTAssertTrue(a.prerelease.isEmpty)
    }

    func test_parsesPrerelease() {
        XCTAssertEqual(v("0.1.0-beta9").prerelease, ["beta9"])
    }

    func test_missingPatchDefaultsToZero() {
        XCTAssertEqual(v("1.2").patch, 0)
    }

    func test_rejectsGarbage() {
        XCTAssertNil(SemanticVersion("not-a-version"))
        XCTAssertNil(SemanticVersion(""))
    }

    func test_coreOrdering() {
        XCTAssertTrue(v("0.1.0") < v("0.2.0"))
        XCTAssertTrue(v("0.9.9") < v("1.0.0"))
        XCTAssertTrue(v("1.0.0") > v("0.9.9"))
    }

    func test_releaseOutranksPrerelease() {
        XCTAssertTrue(v("0.1.0-beta9") < v("0.1.0"))
        XCTAssertFalse(v("0.1.0") < v("0.1.0-beta9"))
    }

    func test_prereleaseNumericOrdering() {
        XCTAssertTrue(v("0.1.0-beta9") < v("0.1.0-beta10"))
    }

    func test_newerCoreBeatsPrerelease() {
        XCTAssertTrue(v("0.1.0-beta9") < v("0.2.0"))
    }

    func test_equalVersionsAreNotLess() {
        XCTAssertFalse(v("0.1.0-beta9") < v("0.1.0-beta9"))
        XCTAssertEqual(v("1.2.3"), v("1.2.3"))
    }
}
