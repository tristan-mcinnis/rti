import RTICore
import XCTest

/// The saved-meeting output store: unique, atomic, owner-only writes with
/// provenance, refusal to overwrite or escape the session, and a cancelled
/// write that leaves nothing behind. Every fixture is invented; nothing here
/// reads the real vault.
final class SessionOutputStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rti-session-output-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures

    private func makeSession(named name: String = "2026-06-08 161305") throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func recipe() -> SessionOutputRecipe {
        SessionOutputRecipe.builtIn(.clientFollowUp, resolve: { _ in "Write a follow-up." })
    }

    private func provenance(
        generatedAt: String = "2026-06-08T16:13:05Z",
        endpoint: String? = "https://api.deepseek.com/v1"
    ) -> SessionOutputProvenance {
        SessionOutputProvenance(
            templateID: "client-follow-up",
            templateName: "Client follow-up draft",
            templateHash: PromptDefaults.fnv1a("Write a follow-up."),
            sourceFile: "transcript.md",
            sourceHash: "deadbeef",
            sourceBytes: 42,
            sessionFolder: "2026-06-08 161305",
            sessionID: "sess-1",
            mode: "Interview",
            providerID: "deepseek",
            providerName: "DeepSeek",
            model: "deepseek-flash",
            endpoint: endpoint,
            generatedAt: generatedAt
        )
    }

    private func outputsURL(_ session: URL) -> URL {
        session.appendingPathComponent("outputs", isDirectory: true)
    }

    // MARK: - Saving

    func testWriteSavesUniqueOwnerOnlyFileWithProvenance() async throws {
        let session = try makeSession()
        let store = SessionOutputStore()
        let now = Date(timeIntervalSince1970: 1_749_400_000)
        let artifact = try await store.write(
            recipe: recipe(), provenance: provenance(), body: "  Hello output.  ", into: session, now: now
        )

        XCTAssertTrue(artifact.url.path.hasPrefix(outputsURL(session).path))
        XCTAssertTrue(artifact.url.lastPathComponent.hasPrefix("client-follow-up-"))
        XCTAssertTrue(artifact.url.lastPathComponent.hasSuffix(".md"))
        XCTAssertEqual(artifact.templateID, "client-follow-up")
        XCTAssertEqual(artifact.templateName, "Client follow-up draft")

        let file = try FileManager.default.attributesOfItem(atPath: artifact.url.path)
        XCTAssertEqual((file[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let folder = try FileManager.default.attributesOfItem(atPath: outputsURL(session).path)
        XCTAssertEqual((folder[.posixPermissions] as? NSNumber)?.intValue, 0o700)

        // No temp file survives.
        let names = try FileManager.default.contentsOfDirectory(atPath: outputsURL(session).path)
        XCTAssertEqual(names, [artifact.url.lastPathComponent])

        let text = try String(contentsOf: artifact.url, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("---\n"))
        XCTAssertTrue(text.contains("# Client follow-up draft"))
        XCTAssertTrue(text.contains("Hello output."))
        XCTAssertFalse(text.contains("  Hello output.  "))

        let parsed = try XCTUnwrap(SessionOutputMarkdown.parseProvenance(text))
        XCTAssertEqual(parsed, provenance())
        XCTAssertEqual(parsed.endpoint, "https://api.deepseek.com/v1")
    }

    func testSecondWriteSameRecipeAndInstantNeverOverwrites() async throws {
        let session = try makeSession()
        let store = SessionOutputStore()
        let now = Date(timeIntervalSince1970: 1_749_400_000)
        let first = try await store.write(
            recipe: recipe(), provenance: provenance(), body: "First body", into: session, now: now
        )
        let second = try await store.write(
            recipe: recipe(), provenance: provenance(), body: "Second body", into: session, now: now
        )
        XCTAssertNotEqual(first.url, second.url)
        XCTAssertTrue(second.url.lastPathComponent.hasSuffix("-2.md"), second.url.lastPathComponent)
        XCTAssertTrue(try String(contentsOf: first.url, encoding: .utf8).contains("First body"))
        XCTAssertTrue(try String(contentsOf: second.url, encoding: .utf8).contains("Second body"))
        // The original file is untouched: nothing was overwritten.
        XCTAssertFalse(try String(contentsOf: first.url, encoding: .utf8).contains("Second body"))
    }

    func testListSortsNewestFirstAndIgnoresNonOutputs() async throws {
        let session = try makeSession()
        let store = SessionOutputStore()
        let older = try await store.write(
            recipe: recipe(),
            provenance: provenance(generatedAt: "2026-06-08T10:00:00Z"),
            body: "older",
            into: session,
            now: Date(timeIntervalSince1970: 1)
        )
        let newer = try await store.write(
            recipe: recipe(),
            provenance: provenance(generatedAt: "2026-06-08T12:00:00Z"),
            body: "newer",
            into: session,
            now: Date(timeIntervalSince1970: 2)
        )
        // Decoys placed by hand: a non-md file, a hidden md, and a folder.
        try Data("x".utf8).write(to: outputsURL(session).appendingPathComponent("notes.txt"))
        try Data("x".utf8).write(to: outputsURL(session).appendingPathComponent(".hidden.md"))
        try FileManager.default.createDirectory(
            at: outputsURL(session).appendingPathComponent("sub.md", isDirectory: true),
            withIntermediateDirectories: true
        )

        let artifacts = SessionOutputStore.list(in: session)
        XCTAssertEqual(artifacts.map(\.url), [newer.url, older.url])
        XCTAssertEqual(artifacts.first?.templateName, "Client follow-up draft")
        XCTAssertNotNil(artifacts.first?.generatedAt)
    }

    func testListOnAnEmptySessionIsEmpty() throws {
        let session = try makeSession()
        XCTAssertTrue(SessionOutputStore.list(in: session).isEmpty)
    }

    func testMalformedProvenanceDoesNotReadBodyAsMetadata() {
        XCTAssertNil(SessionOutputMarkdown.parseProvenance("---\noutput: \"fixture\"\nno closing fence"))
        XCTAssertNil(SessionOutputMarkdown.parseProvenance("---\nmodel: \"fixture\"\n---\nBody"))
        let parsed = SessionOutputMarkdown.parseProvenance("---\noutput: \"fixture\"\nsource-bytes: nope\n---\nBody")
        XCTAssertEqual(parsed?.sourceBytes, 0)
    }

    // MARK: - Refusals

    func testSanitizedEndpointStripsCredentialsAndQuery() {
        XCTAssertEqual(
            SessionOutputMarkdown.sanitizedEndpoint(
                URL(string: "https://user:pass@api.example.com:8443/v1/chat?key=secret#frag")
            ),
            "https://api.example.com:8443"
        )
        XCTAssertEqual(
            SessionOutputMarkdown.sanitizedEndpoint(URL(string: "https://api.example.com/v1")),
            "https://api.example.com"
        )
        XCTAssertNil(SessionOutputMarkdown.sanitizedEndpoint(URL(string: "relative/path")))
        XCTAssertNil(SessionOutputMarkdown.sanitizedEndpoint(URL(string: "mailto:someone@example.com")))
        XCTAssertNil(SessionOutputMarkdown.sanitizedEndpoint(nil))
    }

    func testProvenanceWithoutEndpointOmitsTheLine() async throws {
        let session = try makeSession()
        let store = SessionOutputStore()
        let artifact = try await store.write(
            recipe: recipe(), provenance: provenance(endpoint: nil), body: "body", into: session, now: Date()
        )
        let text = try String(contentsOf: artifact.url, encoding: .utf8)
        XCTAssertFalse(text.contains("\nendpoint:"))
        let parsed = try XCTUnwrap(SessionOutputMarkdown.parseProvenance(text))
        XCTAssertNil(parsed.endpoint)
    }

    func testEmptyBodyIsRefusedAndNothingIsWritten() async throws {
        let session = try makeSession()
        let store = SessionOutputStore()
        do {
            _ = try await store.write(
                recipe: recipe(), provenance: provenance(), body: "   \n\t ", into: session, now: Date()
            )
            XCTFail("expected emptyOutput")
        } catch let error as SessionOutputError {
            XCTAssertEqual(error, .emptyOutput)
        }
        XCTAssertTrue(SessionOutputStore.list(in: session).isEmpty)
    }

    func testUnsafeRecipeIDIsRefusedWithNoFile() async throws {
        let session = try makeSession()
        let store = SessionOutputStore()
        let unsafe = SessionOutputRecipe(id: "../escape", name: "Escape", instruction: "go", origin: .custom)
        do {
            _ = try await store.write(
                recipe: unsafe, provenance: provenance(), body: "x", into: session, now: Date()
            )
            XCTFail("expected refusal")
        } catch let error as SessionOutputError {
            guard case .writeFailed = error else { return XCTFail("expected writeFailed, got \(error)") }
        }
        XCTAssertTrue(SessionOutputStore.list(in: session).isEmpty)
    }

    func testOutputsPathOccupiedByAFileIsAWriteError() async throws {
        let session = try makeSession()
        try Data("not a folder".utf8).write(to: outputsURL(session))
        let store = SessionOutputStore()
        do {
            _ = try await store.write(
                recipe: recipe(), provenance: provenance(), body: "x", into: session, now: Date()
            )
            XCTFail("expected refusal")
        } catch let error as SessionOutputError {
            guard case .writeFailed = error else { return XCTFail("expected writeFailed, got \(error)") }
        }
        // The regular file is untouched.
        XCTAssertEqual(try String(contentsOf: outputsURL(session), encoding: .utf8), "not a folder")
    }

    func testSymlinkedOutputsDirectoryIsRefused() async throws {
        let session = try makeSession()
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: outputsURL(session), withDestinationURL: outside)

        XCTAssertTrue(SessionOutputStore.list(in: session).isEmpty)

        let store = SessionOutputStore()
        do {
            _ = try await store.write(
                recipe: recipe(), provenance: provenance(), body: "x", into: session, now: Date()
            )
            XCTFail("expected refusal")
        } catch let error as SessionOutputError {
            XCTAssertEqual(error, .uncontainedDestination)
        }
        XCTAssertTrue(
            (try? FileManager.default.contentsOfDirectory(atPath: outside.path))?.isEmpty ?? false,
            "nothing may land in the linked folder"
        )
    }

    func testSymlinkedArtifactIsSkippedByList() async throws {
        let session = try makeSession()
        let store = SessionOutputStore()
        _ = try await store.write(
            recipe: recipe(), provenance: provenance(), body: "real", into: session, now: Date()
        )
        let outside = root.appendingPathComponent("stolen.md")
        try Data("secret".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: outputsURL(session).appendingPathComponent("linked.md"),
            withDestinationURL: outside
        )

        let artifacts = SessionOutputStore.list(in: session)
        XCTAssertEqual(artifacts.count, 1)
        XCTAssertFalse(artifacts.contains { $0.url.lastPathComponent == "linked.md" })
    }

    // MARK: - Cancellation

    func testPreCancelledWriteSavesNothing() async throws {
        let session = try makeSession()
        let store = SessionOutputStore()
        let outputRecipe = recipe()
        let outputProvenance = provenance()
        let now = Date(timeIntervalSince1970: 1_749_400_000)

        let task = Task { () throws -> Void in
            _ = try await store.write(
                recipe: outputRecipe, provenance: outputProvenance, body: "Body", into: session, now: now
            )
        }
        task.cancel()
        do {
            try await task.value
            // If the runtime ran the body despite the pre-cancel, the artifact
            // must still be whole, never partial.
            XCTAssertEqual(SessionOutputStore.list(in: session).count, 1)
        } catch is CancellationError {
            XCTAssertTrue(SessionOutputStore.list(in: session).isEmpty, "a cancelled write leaves nothing")
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: outputsURL(session).path),
                "a cancelled write does not even create the folder"
            )
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}
