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

    func testScopedToolsNeedAnExplicitOptIn() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let arguments = MeetingProcessorConfig.permissionArguments(
            config: ["auto_process_scoped_tools": true],
            home: home
        )

        XCTAssertEqual(Array(arguments.prefix(3)), ["--permission-mode", "acceptEdits", "--allowedTools"])
        XCTAssertTrue(arguments.contains("Bash(git -C /Users/test/memory push)"))
        XCTAssertTrue(arguments.contains("Bash(git -C /Users/test/memory add tasks.md)"))
        XCTAssertTrue(arguments.contains("Bash(git -C /Users/test/memory pull --rebase)"))
        XCTAssertEqual(Array(arguments.suffix(2)), ["--add-dir", "/Users/test/memory"])
        XCTAssertEqual(
            MeetingProcessorConfig.permissionArguments(config: ["auto_process_scoped_tools": false], home: home),
            ["--permission-mode", "acceptEdits"]
        )
    }

    func testPermissionsAreNeverSkippedAndNoBareBashIsAllowed() {
        let arguments = MeetingProcessorConfig.permissionArguments(
            config: ["auto_process_scoped_tools": true, "auto_process_yolo": true]
        )

        XCTAssertFalse(arguments.contains("--dangerously-skip-permissions"))
        XCTAssertFalse(arguments.contains("Bash"))
        XCTAssertTrue(arguments.filter { $0.hasPrefix("Bash(") }.allSatisfy { $0.hasSuffix(")") })
    }

    func testAllowedToolsExcludeScriptsReadersAndBareWrites() {
        let tools = MeetingProcessorConfig.allowedTools(home: URL(fileURLWithPath: "/Users/test"))

        XCTAssertEqual(
            tools,
            [
                "Read", "Glob", "Grep",
                "Bash(mkdir *)", "Bash(ls *)",
                "Bash(git -C /Users/test/memory add tasks.md)",
                "Bash(git -C /Users/test/memory commit -m *)",
                "Bash(git -C /Users/test/memory pull --rebase)",
                "Bash(git -C /Users/test/memory push)",
            ]
        )
        XCTAssertFalse(tools.contains { $0.contains("python3") || $0.hasPrefix("Bash(cp") || $0.hasPrefix("Bash(cat") })
        XCTAssertFalse(tools.contains("Write") || tools.contains("Edit"))
    }

    func testWorkingDirectoryIsTheWorkTree() {
        XCTAssertEqual(
            MeetingProcessorConfig.workingDirectory(home: URL(fileURLWithPath: "/Users/test")).path,
            "/Users/test/Documents/Work"
        )
    }
}
