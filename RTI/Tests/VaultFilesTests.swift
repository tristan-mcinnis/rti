import XCTest

/// Locks the path-confinement of VaultFiles.resolve — the security boundary that
/// keeps an untrusted transcript from steering a read outside databases/. These
/// run against the real vault location (resolved via Sentinel config); if that
/// can't be found, resolve returns nil and the refusal assertions still hold.
final class VaultFilesTests: XCTestCase {
    func testInProjectPathResolvesOrNilButNeverEscapes() {
        // A normal in-vault path either resolves (vault present) or is nil
        // (vault not locatable in this environment) — never something outside.
        let u = VaultFiles.resolve("projects/foo/00-status.md")
        if let u { XCTAssertTrue(u.path.contains("/databases/")) }
    }

    func testParentTraversalRefused() {
        XCTAssertNil(VaultFiles.resolve("../../.ssh/id_rsa"))
        XCTAssertNil(VaultFiles.resolve("projects/../../secrets.env"))
    }

    func testAbsolutePathConfinedNotEscaped() {
        // An absolute path isn't an escape — the leading slash is stripped and it
        // is confined under databases/ (a harmless non-existent path), never the
        // real /etc/passwd or ~/.ssh. The security property is "never outside",
        // not "always nil".
        for p in ["/etc/passwd", "/Users/user/.ssh/id_rsa"] {
            if let u = VaultFiles.resolve(p) {
                XCTAssertTrue(u.path.contains("/databases/"))
                XCTAssertFalse(u.path == "/etc/passwd")
            }
        }
    }

    func testLeadingPrefixesAreStripped() {
        // These shapes (as other tools print them) must not be treated as escapes.
        let a = VaultFiles.resolve("databases/projects/foo/x.md")
        let b = VaultFiles.resolve("vault/databases/projects/foo/x.md")
        for u in [a, b].compactMap({ $0 }) {
            XCTAssertTrue(u.path.hasSuffix("/projects/foo/x.md"))
        }
    }

    func testReadRefusesEscape() {
        XCTAssertTrue(VaultFiles.read(relativePath: "../../.ssh/id_rsa").hasPrefix("Refused:"))
    }

    func testResolveMention_emptyQueryIsMissing() {
        if case let .missing(query) = VaultFiles.resolveMention("   ", scopeRelativePath: nil) {
            XCTAssertEqual(query, "   ")
        } else {
            XCTFail("Expected empty mention to be reported missing")
        }
    }

    func testResolveMention_nonexistentQueryIsMissing() {
        if case let .missing(query) = VaultFiles.resolveMention("__definitely_not_a_real_rti_doc__", scopeRelativePath: nil) {
            XCTAssertEqual(query, "__definitely_not_a_real_rti_doc__")
        } else {
            XCTFail("Expected unknown mention to be reported missing")
        }
    }
}
