import Darwin
import XCTest
import RTICore

/// The control socket: verb parsing, idempotency, the status document, the
/// manifest against the house contract, path resolution, and one real socket
/// on a temporary path. The real socket at `~/.config/rti/control.sock` is
/// never touched by these tests.
final class ControlSocketTests: XCTestCase {

    // MARK: - Verbs

    func testParseIsCaseInsensitiveAndTrims() {
        XCTAssertEqual(ControlVerb.parse(" Start\n"), .start)
        XCTAssertEqual(ControlVerb.parse("STOP"), .stop)
        XCTAssertEqual(ControlVerb.parse("toggle\r\n"), .toggle)
        XCTAssertEqual(ControlVerb.parse("\tstatus\t"), .status)
    }

    func testParseDropsArgumentTextAfterTheVerb() {
        XCTAssertEqual(ControlVerb.parse("start now please"), .start)
        XCTAssertEqual(ControlVerb.parse("sessions 2026-09-12"), .sessions)
    }

    func testUnknownAndEmptyLinesDoNotParse() {
        XCTAssertNil(ControlVerb.parse("nonsense"))
        XCTAssertNil(ControlVerb.parse(""))
        XCTAssertNil(ControlVerb.parse("   \n"))
        XCTAssertNil(ControlVerb.parse("delete"))
    }

    func testEveryVerbRoundTripsThroughItsWireWord() {
        for verb in ControlVerb.allCases {
            XCTAssertEqual(ControlVerb.parse(verb.rawValue), verb)
        }
    }

    func testToggleResolvesBeforeDispatchAndConcreteVerbsPassThrough() {
        XCTAssertEqual(ControlVerb.toggle.resolved(recording: false), .start)
        XCTAssertEqual(ControlVerb.toggle.resolved(recording: true), .stop)
        for verb in ControlVerb.allCases where verb != .toggle {
            XCTAssertEqual(verb.resolved(recording: true), verb)
            XCTAssertEqual(verb.resolved(recording: false), verb)
        }
    }

    // MARK: - Protocol replies

    func testUnknownVerbRepliesWithAnErrorAndDispatchesNothing() {
        let recorder = VerbRecorder()
        let server = ControlSocketServer(log: { _ in }, dispatch: { recorder.record($0) })

        XCTAssertEqual(server.reply(to: "nonsense"), #"err unknown command "nonsense""#)
        XCTAssertEqual(recorder.verbs, [])
    }

    /// The error names the word that was not understood, so a typo is
    /// recognisable to whoever sent it. Same shape as local-dictation's
    /// `ipc.rs`.
    func testTheErrorNamesTheOffendingWord() {
        let server = ControlSocketServer(log: { _ in }, dispatch: { _ in })

        XCTAssertEqual(server.reply(to: "frobnicate"), #"err unknown command "frobnicate""#)
        XCTAssertEqual(server.reply(to: "Strt\n"), #"err unknown command "Strt""#)
        // Argument text is not part of the offending word.
        XCTAssertEqual(server.reply(to: "wibble now please"), #"err unknown command "wibble""#)
        // An empty line names an empty word rather than replying nothing.
        XCTAssertEqual(server.reply(to: ""), #"err unknown command """#)
        XCTAssertEqual(server.reply(to: "   \n"), #"err unknown command """#)
    }

    /// A garbage request must never be able to forge a second reply line.
    func testTheErrorReplyStaysOnOneLine() {
        let server = ControlSocketServer(log: { _ in }, dispatch: { _ in })

        let reply = server.reply(to: "a\u{7}b\"c\\d")
        XCTAssertFalse(reply.contains("\n"))
        XCTAssertTrue(reply.hasPrefix("err unknown command "))
        XCTAssertTrue(reply.contains(#"\""#), "a quote must be escaped: \(reply)")
        XCTAssertTrue(reply.contains(#"\u0007"#), "a control byte must be escaped: \(reply)")
    }

    /// Every reply is one line, whatever came in.
    func testEveryReplyIsASingleLine() {
        let server = ControlSocketServer(log: { _ in }, dispatch: { _ in })
        for request in ["start", "status", "toggle", "nonsense", "", "stop extra words"] {
            XCTAssertFalse(server.reply(to: request).contains("\n"), "reply to \(request) spans lines")
        }
    }

    /// The contract's idempotency rule: `stop` on a stopped app is a no-op
    /// that replies success, not an error. Its manifest clause (`!recording`)
    /// is a display hint that dims the launcher's row — it must never make the
    /// socket refuse the command.
    func testStopWhileIdleRepliesSuccess() {
        let recorder = VerbRecorder()
        let server = ControlSocketServer(log: { _ in }, dispatch: { recorder.record($0) })
        server.update(.idle)

        XCTAssertEqual(server.reply(to: "stop"), "ok stop")
        XCTAssertEqual(server.reply(to: "resume"), "ok resume")
        XCTAssertEqual(recorder.verbs, [.stop, .resume])
    }

    func testToggleIsResolvedBeforeItIsDispatched() {
        let recorder = VerbRecorder()
        let server = ControlSocketServer(log: { _ in }, dispatch: { recorder.record($0) })

        server.update(.idle)
        XCTAssertEqual(server.reply(to: "toggle"), "ok start")

        server.update(ControlSnapshot(recording: true, label: "Recording"))
        XCTAssertEqual(server.reply(to: "toggle"), "ok stop")

        XCTAssertEqual(recorder.verbs, [.start, .stop])
        XCTAssertFalse(recorder.verbs.contains(.toggle), "toggle must never reach the app")
    }

    func testStatusIsAnsweredWithoutDispatchingAnything() {
        let recorder = VerbRecorder()
        let server = ControlSocketServer(log: { _ in }, dispatch: { recorder.record($0) })

        XCTAssertTrue(server.reply(to: "status").hasPrefix("{"))
        XCTAssertEqual(recorder.verbs, [])
    }

    // MARK: - The status document

    func testStatusDocumentCarriesTheContractFields() throws {
        let now = Date()
        let snapshot = ControlSnapshot.forSession(phase: .recording, elapsed: 763, now: now)
        let document = try json(snapshot.statusLine(at: now))

        XCTAssertEqual(document["app"] as? String, "rti")
        XCTAssertEqual(document["ok"] as? Bool, true)
        XCTAssertEqual(document["busy"] as? Bool, false)
        XCTAssertEqual(document["recording"] as? Bool, true)
        XCTAssertEqual(document["paused"] as? Bool, false)
        XCTAssertEqual(document["detail"] as? String, "Recording, 12:43")
    }

    func testStatusIsOneLineOfJSON() {
        let line = ControlSnapshot.forSession(phase: .paused, elapsed: 61, now: Date()).statusLine()
        XCTAssertFalse(line.contains("\n"))
    }

    func testEveryPhaseReportsItsOwnStateAndDetail() throws {
        let now = Date()
        let expectations: [(SessionPhase, Bool, Bool, Bool, String)] = [
            (.idle, false, false, false, "Idle"),
            (.recording, true, false, false, "Recording, 0:30"),
            (.paused, true, true, false, "Paused, 0:30"),
            (.finishing, false, false, true, "Finishing, 0:30"),
            (.summarizing, false, false, true, "Summarizing, 0:30"),
            (.done, false, false, false, "Notes ready, 0:30"),
        ]

        for (phase, recording, paused, busy, detail) in expectations {
            let snapshot = ControlSnapshot.forSession(phase: phase, elapsed: phase == .idle ? 0 : 30, now: now)
            let document = try json(snapshot.statusLine(at: now))
            XCTAssertEqual(document["recording"] as? Bool, recording, "\(phase) recording")
            XCTAssertEqual(document["paused"] as? Bool, paused, "\(phase) paused")
            XCTAssertEqual(document["busy"] as? Bool, busy, "\(phase) busy")
            XCTAssertEqual(document["detail"] as? String, detail, "\(phase) detail")
        }
    }

    /// `stop` must stay available while paused, so a paused session still
    /// reads as recording.
    func testAPausedSessionStillCountsAsRecording() {
        let snapshot = ControlSnapshot.forSession(phase: .paused, elapsed: 5, now: Date())
        XCTAssertTrue(snapshot.recording)
        XCTAssertTrue(snapshot.paused)
    }

    /// The readout moves on its own: one snapshot taken at the start of a
    /// recording still answers correctly a minute later.
    func testARunningClockAdvancesWithoutARefreshedSnapshot() {
        let start = Date()
        let snapshot = ControlSnapshot.forSession(phase: .recording, elapsed: 0, now: start)
        XCTAssertEqual(snapshot.detail(at: start), "Recording, 0:00")
        XCTAssertEqual(snapshot.detail(at: start.addingTimeInterval(75)), "Recording, 1:15")
    }

    func testAFrozenClockStandsStill() {
        let start = Date()
        let snapshot = ControlSnapshot.forSession(phase: .paused, elapsed: 90, now: start)
        XCTAssertEqual(snapshot.detail(at: start.addingTimeInterval(600)), "Paused, 1:30")
    }

    // MARK: - The manifest

    func testManifestMatchesTheHouseContract() throws {
        let document = try json(String(decoding: ControlManifest.json(socketPath: "/tmp/x/control.sock"), as: UTF8.self))

        XCTAssertEqual(document["schema"] as? Int, 1)
        XCTAssertEqual(document["app"] as? String, "rti")
        XCTAssertEqual(document["name"] as? String, "RTI")
        XCTAssertEqual(document["transport"] as? String, "socket")
        XCTAssertEqual(document["endpoint"] as? String, "/tmp/x/control.sock")
        XCTAssertEqual(document["status"] as? String, "status")

        let commands = try XCTUnwrap(document["commands"] as? [[String: Any]])
        XCTAssertEqual(commands.count, 5)
        for command in commands {
            XCTAssertFalse((command["id"] as? String ?? "").isEmpty)
            XCTAssertFalse((command["title"] as? String ?? "").isEmpty)
            let verb = try XCTUnwrap(command["verb"] as? String)
            XCTAssertNotNil(ControlVerb(rawValue: verb), "\(verb) is not a verb the listener answers")
            // `needs` is null, "text" or "choice".
            if let needs = command["needs"] as? String {
                XCTAssertTrue(["text", "choice"].contains(needs))
            } else {
                XCTAssertTrue(command["needs"] is NSNull)
            }
        }
    }

    /// `unavailableWhen` must name a boolean the status document actually
    /// carries, or Quick Launch would be guessing.
    func testEveryUnavailableWhenClauseNamesABooleanInTheStatusDocument() throws {
        let status = try json(ControlSnapshot.idle.statusLine())
        for command in ControlManifest.commands {
            guard let clause = command.unavailableWhen else { continue }
            let field = clause.hasPrefix("!") ? String(clause.dropFirst()) : clause
            XCTAssertTrue(status[field] is Bool, "\(command.id): status has no boolean '\(field)'")
        }
    }

    /// Whatever the clauses say, every command in the manifest succeeds in
    /// every session state. A dimmed row and a refused command are different
    /// things.
    func testNoManifestClauseEverRefusesACommand() {
        let phases: [SessionPhase] = [.idle, .recording, .paused, .finishing, .summarizing, .done]
        for phase in phases {
            let recorder = VerbRecorder()
            let server = ControlSocketServer(log: { _ in }, dispatch: { recorder.record($0) })
            server.update(ControlSnapshot.forSession(phase: phase, elapsed: 10, now: Date()))
            for command in ControlManifest.commands {
                XCTAssertEqual(
                    server.reply(to: command.verb.rawValue),
                    "ok \(command.verb.rawValue)",
                    "\(command.id) was refused while \(phase)"
                )
            }
        }
    }

    func testStartAndStopAreGatedOnTheRecordingFlag() throws {
        let byID = Dictionary(uniqueKeysWithValues: ControlManifest.commands.map { ($0.id, $0) })
        XCTAssertEqual(byID["record.start"]?.unavailableWhen, "recording")
        XCTAssertEqual(byID["record.stop"]?.unavailableWhen, "!recording")
        XCTAssertEqual(byID["record.pause"]?.unavailableWhen, "!canPause")
        XCTAssertEqual(byID["record.resume"]?.unavailableWhen, "!canResume")
    }

    /// A row is offered only when the verb would actually do something. The
    /// user is never shown a command that is a no-op.
    func testCanPauseAndCanResumeAreTrueOnlyWhenTheVerbWouldDoSomething() {
        let now = Date()
        let expectations: [(SessionPhase, Bool, Bool)] = [
            (.idle, false, false),
            (.recording, true, false),
            (.paused, false, true),
            (.finishing, false, false),
            (.summarizing, false, false),
            (.done, false, false),
        ]

        for (phase, canPause, canResume) in expectations {
            let snapshot = ControlSnapshot.forSession(phase: phase, elapsed: 10, now: now)
            XCTAssertEqual(snapshot.canPause, canPause, "\(phase) canPause")
            XCTAssertEqual(snapshot.canResume, canResume, "\(phase) canResume")
            // The two are never both true: nothing is pausable and resumable.
            XCTAssertFalse(snapshot.canPause && snapshot.canResume, "\(phase)")
        }
    }

    func testStatusDocumentCarriesTheGatingBooleans() throws {
        let now = Date()
        for phase in [SessionPhase.idle, .recording, .paused, .finishing, .summarizing, .done] {
            let snapshot = ControlSnapshot.forSession(phase: phase, elapsed: 10, now: now)
            let document = try json(snapshot.statusLine(at: now))
            XCTAssertEqual(document["canPause"] as? Bool, snapshot.canPause, "\(phase) canPause")
            XCTAssertEqual(document["canResume"] as? Bool, snapshot.canResume, "\(phase) canResume")
        }
    }

    /// The contract's safety rule: nothing that deletes or overwrites a
    /// session may be driven from outside.
    func testNoCommandDestroysData() {
        let destructive = ["delete", "clear", "remove", "erase", "overwrite", "reset", "quit"]
        for command in ControlManifest.commands {
            for word in destructive {
                XCTAssertFalse(command.id.lowercased().contains(word), command.id)
                XCTAssertFalse(command.title.lowercased().contains(word), command.title)
            }
        }
    }

    /// Readers never expand paths themselves, so the endpoint carries the
    /// resolved absolute path.
    func testManifestEndpointIsAnAbsolutePath() throws {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".config/rti", isDirectory: true)
        let socket = ControlPaths.socketURL(configHome: home, environment: [:])
        let document = try json(String(decoding: try ControlManifest.json(socketPath: socket.path), as: UTF8.self))

        let endpoint = try XCTUnwrap(document["endpoint"] as? String)
        XCTAssertTrue(endpoint.hasPrefix("/"), endpoint)
        XCTAssertFalse(endpoint.contains("~"), endpoint)
        XCTAssertTrue(endpoint.hasSuffix("/.config/rti/control.sock"), endpoint)
    }

    func testManifestSerializationIsStable() throws {
        let first = try ControlManifest.json(socketPath: "/tmp/a.sock")
        let second = try ControlManifest.json(socketPath: "/tmp/a.sock")
        XCTAssertEqual(first, second)
    }

    // MARK: - Paths

    func testSocketPathDefaultsToTheConfigDirectory() {
        let home = URL(fileURLWithPath: "/Users/someone/.config/rti", isDirectory: true)
        let resolved = ControlPaths.socketURL(configHome: home, environment: [:])
        XCTAssertEqual(resolved.path, "/Users/someone/.config/rti/control.sock")
        XCTAssertFalse(resolved.path.contains(NSTemporaryDirectory()), "the socket must never live in temp_dir()")
    }

    func testSocketPathHonoursTheEnvironmentOverride() {
        let home = URL(fileURLWithPath: "/Users/someone/.config/rti", isDirectory: true)
        let environment = [ControlPaths.socketEnvironmentKey: "/tmp/custom-rti.sock"]
        XCTAssertEqual(ControlPaths.socketURL(configHome: home, environment: environment).path, "/tmp/custom-rti.sock")
    }

    func testABlankOverrideFallsThroughToTheDefault() {
        let home = URL(fileURLWithPath: "/Users/someone/.config/rti", isDirectory: true)
        let environment = [ControlPaths.socketEnvironmentKey: "   "]
        XCTAssertEqual(ControlPaths.socketURL(configHome: home, environment: environment).path, "/Users/someone/.config/rti/control.sock")
    }

    func testManifestPathIsTheSharedHouseDirectory() {
        let base = URL(fileURLWithPath: "/Users/someone/Library/Application Support", isDirectory: true)
        XCTAssertEqual(
            ControlPaths.manifestURL(applicationSupport: base, environment: [:]).path,
            "/Users/someone/Library/Application Support/House/commands/rti.json"
        )
    }

    func testManifestPathHonoursTheEnvironmentOverride() {
        let base = URL(fileURLWithPath: "/Users/someone/Library/Application Support", isDirectory: true)
        let environment = [ControlPaths.manifestEnvironmentKey: "/tmp/house-commands"]
        XCTAssertEqual(
            ControlPaths.manifestURL(applicationSupport: base, environment: environment).path,
            "/tmp/house-commands/rti.json"
        )
    }

    // MARK: - A real socket, on a temporary path

    func testServerAnswersOverARealSocket() throws {
        let recorder = VerbRecorder()
        let path = temporarySocketPath()
        let server = ControlSocketServer(log: { _ in }, dispatch: { recorder.record($0) })
        XCTAssertTrue(server.start(at: path))
        defer { server.stop() }

        server.update(ControlSnapshot.forSession(phase: .idle, elapsed: 0, now: Date()))
        XCTAssertEqual(try send("toggle", to: path), "ok start")
        XCTAssertEqual(try send("nonsense", to: path), #"err unknown command "nonsense""#)

        server.update(ControlSnapshot.forSession(phase: .recording, elapsed: 12, now: Date()))
        let status = try json(try send("status", to: path))
        XCTAssertEqual(status["recording"] as? Bool, true)
        XCTAssertEqual(status["detail"] as? String, "Recording, 0:12")

        XCTAssertEqual(try send("stop", to: path), "ok stop")
        XCTAssertEqual(recorder.verbs, [.start, .stop])
    }

    func testTheSocketFileIsPrivateToTheUser() throws {
        let path = temporarySocketPath()
        let server = ControlSocketServer(log: { _ in }, dispatch: { _ in })
        XCTAssertTrue(server.start(at: path))
        defer { server.stop() }

        let mode = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.int16Value, 0o600)
    }

    func testAStaleSocketFileDoesNotBlockBinding() throws {
        let path = temporarySocketPath()
        let first = ControlSocketServer(log: { _ in }, dispatch: { _ in })
        XCTAssertTrue(first.start(at: path))
        // Leave the file behind, as a crashed run would.
        first.stop()
        try? Data().write(to: path)

        let second = ControlSocketServer(log: { _ in }, dispatch: { _ in })
        XCTAssertTrue(second.start(at: path), "a stale socket file must be cleared before bind()")
        defer { second.stop() }
        XCTAssertEqual(try send("status", to: path).isEmpty, false)
    }

    func testStopRemovesTheSocketFile() {
        let path = temporarySocketPath()
        let server = ControlSocketServer(log: { _ in }, dispatch: { _ in })
        XCTAssertTrue(server.start(at: path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }

    /// A socket that cannot be bound is reported, not fatal — the app must
    /// still record.
    func testAnUnbindableSocketIsSurvivable() {
        let logged = MessageRecorder()
        let server = ControlSocketServer(log: { logged.record($0) }, dispatch: { _ in })
        let tooLong = URL(fileURLWithPath: "/tmp/" + String(repeating: "x", count: 120) + ".sock")

        XCTAssertFalse(server.start(at: tooLong))
        XCTAssertFalse(logged.messages.isEmpty, "a bind failure must be logged")
        // And the object stays usable: the protocol still answers in-process.
        XCTAssertEqual(server.reply(to: "status").hasPrefix("{"), true)
    }

    // MARK: - Helpers

    private func json(_ line: String) throws -> [String: Any] {
        let data = Data(line.utf8)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func temporarySocketPath() -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rti-control-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("control.sock")
    }

    /// A minimal client: connect, write one line, read one line. Lives here
    /// because the tests are its only caller.
    private func send(_ request: String, to url: URL, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        try XCTUnwrap(fd >= 0 ? true : nil, "socket() failed", file: file, line: line)
        defer { close(fd) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(url.path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try XCTUnwrap(connected == 0 ? true : nil, "connect() failed (errno \(errno))", file: file, line: line)

        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let outgoing = Array((request + "\n").utf8)
        _ = outgoing.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
        shutdown(fd, SHUT_WR)

        var reply = [UInt8]()
        var byte: UInt8 = 0
        while reply.count < 4096 {
            let count = read(fd, &byte, 1)
            if count <= 0 { break }
            if byte == UInt8(ascii: "\n") { break }
            reply.append(byte)
        }
        return String(decoding: reply, as: UTF8.self)
    }
}

/// Collects the verbs the listener dispatched. The dispatch closure is called
/// from the socket thread, so the array is lock-guarded.
private final class VerbRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ControlVerb] = []

    var verbs: [ControlVerb] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ verb: ControlVerb) {
        lock.lock()
        storage.append(verb)
        lock.unlock()
    }
}

/// Same, for the log closure.
private final class MessageRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var messages: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ message: String) {
        lock.lock()
        storage.append(message)
        lock.unlock()
    }
}
