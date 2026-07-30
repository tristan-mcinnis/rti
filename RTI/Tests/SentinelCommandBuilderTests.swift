import XCTest
@testable import RTICore

final class SentinelCommandBuilderTests: XCTestCase {
    func testStartDefaultsToDualChannelAndCarriesProject() {
        XCTAssertEqual(
            SentinelCommandBuilder.start(name: "Acme / Weekly Sync", project: "acme-redesign"),
            [
                "start", "--dual-channel", "--name", "acme-weekly-sync",
                "--project", "acme-redesign",
            ]
        )
    }

    func testStartOmitsBlankProject() {
        XCTAssertEqual(
            SentinelCommandBuilder.start(name: "Team Stand-up", project: "  "),
            ["start", "--dual-channel", "--name", "team-stand-up"]
        )
    }

    func testImportPreservesLiteralFilePathAsOneArgument() {
        XCTAssertEqual(
            SentinelCommandBuilder.transcribe(
                file: "/tmp/Meeting with spaces.m4a",
                project: "project-one"
            ),
            [
                "transcribe", "/tmp/Meeting with spaces.m4a",
                "--project", "project-one",
            ]
        )
    }
}
