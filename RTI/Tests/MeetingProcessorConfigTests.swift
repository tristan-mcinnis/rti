import XCTest
import RTICore

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
        XCTAssertEqual(MeetingProcessorConfig.permissionArguments(config: [:]).prefix(2), ["--permission-mode", "acceptEdits"])
        XCTAssertFalse(MeetingProcessorConfig.permissionArguments(config: [:]).contains("--allowedTools"))
        XCTAssertFalse(MeetingProcessorConfig.permissionArguments(config: ["auto_process": true]).contains("--allowedTools"))
    }

    func testScopedToolsNeedAnExplicitOptIn() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let arguments = MeetingProcessorConfig.permissionArguments(
            config: ["auto_process_scoped_tools": true],
            home: home
        )

        XCTAssertEqual(Array(arguments.prefix(2)), ["--permission-mode", "acceptEdits"])
        XCTAssertTrue(arguments.contains("--allowedTools"))
        XCTAssertTrue(arguments.contains("Bash(git -C /Users/test/memory push)"))
        XCTAssertTrue(arguments.contains("Bash(git -C /Users/test/memory add tasks/cs-work.md)"))
        XCTAssertFalse(arguments.contains("Bash(git -C /Users/test/memory add tasks.md)"))
        XCTAssertTrue(arguments.contains("Bash(git -C /Users/test/memory pull --rebase)"))
        XCTAssertEqual(Array(arguments.suffix(2)), ["--add-dir", "/Users/test/memory"])
        XCTAssertFalse(
            MeetingProcessorConfig.permissionArguments(config: ["auto_process_scoped_tools": false], home: home)
                .contains("--allowedTools")
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

    func testRunIgnoresUserSettingsAndMCPButKeepsTheSendGuard() throws {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        for config in [[:], ["auto_process_scoped_tools": true]] as [[String: Any]] {
            let arguments = MeetingProcessorConfig.permissionArguments(config: config, home: home)
            let sources = try XCTUnwrap(arguments.firstIndex(of: "--setting-sources"))
            XCTAssertEqual(arguments[sources + 1], "project,local")
            XCTAssertTrue(arguments.contains("--strict-mcp-config"))
            XCTAssertFalse(arguments.contains("--dangerously-skip-permissions"))
            let settings = try XCTUnwrap(arguments.firstIndex(of: "--settings"))
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(arguments[settings + 1].utf8)) as? [String: Any]
            )
            XCTAssertEqual(Set(json.keys), ["hooks"])
            let hooks = try XCTUnwrap(json["hooks"] as? [String: Any])
            XCTAssertEqual(Set(hooks.keys), ["PreToolUse"])
            XCTAssertTrue(arguments[settings + 1].contains("python3 /Users/test/skills/_lib/guards/guard-send-gates.py"))
            let denied = try XCTUnwrap(arguments.firstIndex(of: "--disallowedTools"))
            XCTAssertEqual(
                Array(arguments[(denied + 1)...].prefix(9)),
                ["WebFetch", "WebSearch", "Bash(curl *)",
                 "Bash(rm *)", "Bash(rmdir *)", "Bash(mv *)", "Bash(cp *)", "Bash(sed *)", "Bash(touch *)"]
            )
        }
    }

    func testAllowedToolsExcludeScriptsReadersAndBareWrites() {
        let tools = MeetingProcessorConfig.allowedTools(home: URL(fileURLWithPath: "/Users/test"))

        XCTAssertEqual(
            tools,
            [
                "Read", "Glob", "Grep",
                "Bash(mkdir -p /Users/test/Documents/Work/*)", "Bash(ls *)",
            ]
            + ["cs-web", "cs-work", "inner-chapter", "harness", "personal", "finance"].flatMap { lane in
                [
                    "Bash(git -C /Users/test/memory add tasks/\(lane).md)",
                    "Bash(git -C /Users/test/memory commit -m meeting-tasks -- tasks/\(lane).md)",
                ]
            }
            + [
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

/// The unattended run's exit status reaches the RTI log, never its transcript.
final class MeetingProcessorExitLogTests: XCTestCase {
    func testCleanExitLogsNothing() {
        XCTAssertNil(MeetingProcessorConfig.exitLogLine(name: "a.md", status: 0, reason: .exit))
    }

    func testNonZeroExitLogsOneLineWithStatusOnly() throws {
        let line = try XCTUnwrap(MeetingProcessorConfig.exitLogLine(name: "a.md", status: 2, reason: .exit))
        XCTAssertEqual(line, "meeting processor exited with status 2 for a.md")
        XCTAssertFalse(line.contains("\n"))
    }

    func testSignalTerminationIsLogged() throws {
        let line = try XCTUnwrap(MeetingProcessorConfig.exitLogLine(name: "a.md", status: 9, reason: .uncaughtSignal))
        XCTAssertEqual(line, "meeting processor killed by signal 9 for a.md")
    }
}
