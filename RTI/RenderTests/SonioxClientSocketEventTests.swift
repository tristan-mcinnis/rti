import RTICore
import Starscream
import XCTest

/// Which socket events move a `SonioxClient`.
///
/// A leg's socket is replaced whenever it reconnects or the system leg parks
/// and rejoins. The old socket keeps reporting its own teardown afterwards, and
/// those events used to be applied to the new socket: its audio was dropped and
/// a reconnect orphaned it while it kept delivering words. A server that closed
/// the TCP connection without a close frame (`.peerClosed`) was ignored, so the
/// leg kept reading "live" with nothing arriving.
///
/// This lives beside the render proofs because `RTITests` compiles no app
/// sources and cannot see `SonioxClient`. No test here opens a network socket.
@MainActor
final class SonioxClientSocketEventTests: XCTestCase {
    private let unreachable = URL(string: "ws://127.0.0.1:9/")!

    private func makeSocket() -> WebSocket {
        WebSocket(request: URLRequest(url: unreachable))
    }

    /// Collects every status the client reports, for `wait` seconds.
    private func statuses(
        of client: SonioxClient,
        after feed: () -> Void,
        wait: TimeInterval = 0.3
    ) async throws -> [TranscriptionHealth] {
        var seen: [TranscriptionHealth] = []
        client.onStatus = { seen.append($0) }
        feed()
        try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        return seen
    }

    func test_aReplacedSocketsTeardown_doesNotReconnectTheCurrentOne() async throws {
        let client = SonioxClient(apiKey: "test", url: unreachable)
        let current = makeSocket()
        let replaced = makeSocket()
        client.adoptSocketForTesting(current)
        defer { client.disconnect() }

        let seen = try await statuses(of: client) {
            client.didReceive(event: .disconnected("going away", 1000), client: replaced)
            client.didReceive(event: .cancelled, client: replaced)
            client.didReceive(event: .peerClosed, client: replaced)
        }
        XCTAssertEqual(seen, [], "an old socket's teardown is not the current socket's drop")
    }

    func test_thePeerClosingTheCurrentSocket_isADropThatReconnects() async throws {
        let client = SonioxClient(apiKey: "test", url: unreachable)
        let current = makeSocket()
        client.adoptSocketForTesting(current)
        defer { client.disconnect() }

        let seen = try await statuses(of: client) {
            client.didReceive(event: .peerClosed, client: current)
        }
        XCTAssertEqual(seen, [.reconnecting], "a closed connection must not keep reading live")
    }

    func test_replacedSocketTextCannotChangeCurrentTranscriptOrHealth() async throws {
        let client = SonioxClient(apiKey: "test", url: unreachable)
        let current = makeSocket()
        let replaced = makeSocket()
        client.adoptSocketForTesting(current)
        defer { client.disconnect() }
        var words: [SonioxWord] = []
        var errors: [SonioxFailure] = []
        client.onWords = { words += $0 }
        client.onError = { failure, _ in errors.append(failure) }

        let seen = try await statuses(of: client) {
            client.didReceive(event: .text(Self.finalToken), client: replaced)
            client.didReceive(event: .text(#"{"error_code":408,"error_message":"old stream timed out"}"#), client: replaced)
            client.didReceive(event: .text(#"{"error_code":401,"error_message":"old stream rejected"}"#), client: replaced)
        }

        XCTAssertTrue(words.isEmpty, "old stream tokens must not enter the current timeline")
        XCTAssertTrue(errors.isEmpty, "old stream errors must not fail the current stream")
        XCTAssertEqual(seen, [], "old stream errors must not reconnect the current stream")
    }

    func test_currentSocketFinalsStillArriveWhileFinalizing() async throws {
        let client = SonioxClient(apiKey: "test", url: unreachable)
        let current = makeSocket()
        client.adoptSocketForTesting(current)
        defer { client.disconnect() }
        var words: [SonioxWord] = []
        client.onWords = { words += $0 }

        _ = try await statuses(of: client) {
            client.didReceive(event: .connected([:]), client: current)
            client.finalize()
            client.didReceive(event: .text(Self.finalToken), client: current)
        }

        XCTAssertEqual(words.map(\.text), ["Hello"])
        XCTAssertTrue(words.allSatisfy(\.isFinal))
    }

    func testQueuedWordsHealthAndFailureAreDiscardedWhenSocketIsReplaced() async {
        let client = SonioxClient(apiKey: "test", url: unreachable)
        let old = makeSocket()
        client.adoptSocketForTesting(old)
        defer { client.disconnect() }
        var words: [SonioxWord] = []
        var health: [TranscriptionHealth] = []
        var failures: [SonioxFailure] = []
        client.onWords = { words += $0 }
        client.onStatus = { health.append($0) }
        client.onError = { failure, _ in failures.append(failure) }
        // All three events are current at receipt, but delivery is queued.
        client.didReceive(event: .connected([:]), client: old)
        client.didReceive(event: .text(Self.finalToken), client: old)
        client.didReceive(event: .text(#"{"error_code":401,"error_message":"old auth failure"}"#), client: old)
        let current = makeSocket()
        client.adoptSocketForTesting(current)
        await drainCallbacks()
        XCTAssertTrue(words.isEmpty)
        XCTAssertTrue(health.isEmpty)
        XCTAssertTrue(failures.isEmpty)
        client.didReceive(event: .connected([:]), client: current)
        client.finalize()
        client.didReceive(event: .text(Self.finalToken), client: current)
        await drainCallbacks()
        XCTAssertEqual(words.map(\.text), ["Hello"])
        XCTAssertEqual(health, [.live])
    }

    func testDisconnectDiscardsAlreadyQueuedWordsAndHealth() async {
        let client = SonioxClient(apiKey: "test", url: unreachable)
        let socket = makeSocket()
        client.adoptSocketForTesting(socket)
        var deliveries = 0
        client.onWords = { _ in deliveries += 1 }
        client.onStatus = { _ in deliveries += 1 }
        client.onError = { _, _ in deliveries += 1 }
        client.didReceive(event: .text(Self.finalToken), client: socket)
        client.didReceive(event: .peerClosed, client: socket)
        client.disconnect()
        // Parking/rejoining reuses the client but replaces its stream before
        // the queued old callback can drain.
        let rejoined = makeSocket()
        client.adoptSocketForTesting(rejoined)
        await drainCallbacks()
        XCTAssertEqual(deliveries, 0)
        client.didReceive(event: .text(Self.finalToken), client: rejoined)
        await drainCallbacks()
        XCTAssertEqual(deliveries, 1)
        client.disconnect()
    }

    func testFinishWhileDisconnectedRetiresScheduledRetry() throws {
        let client = SonioxClient(apiKey: "test", url: unreachable)
        let socket = makeSocket()
        client.adoptSocketForTesting(socket)
        defer { client.disconnect() }
        client.didReceive(event: .peerClosed, client: socket)
        let retry = try XCTUnwrap(client.pendingReconnectForTesting())
        client.finalize()
        XCTAssertTrue(retry.isCancelled)
        XCTAssertNil(client.pendingReconnectForTesting())
    }

    func testQueuedRetryCannotReplaceNewerSocket() async throws {
        let client = SonioxClient(apiKey: "test", url: unreachable)
        let old = makeSocket()
        client.adoptSocketForTesting(old)
        defer { client.disconnect() }
        client.didReceive(event: .peerClosed, client: old)
        let oldRetry = try XCTUnwrap(client.pendingReconnectForTesting())
        let current = makeSocket()
        client.adoptSocketForTesting(current)
        oldRetry.perform()
        var words: [SonioxWord] = []
        client.onWords = { words += $0 }
        client.didReceive(event: .text(Self.finalToken), client: current)
        await drainCallbacks()
        XCTAssertEqual(words.map(\.text), ["Hello"], "A queued old retry cannot replace the adopted stream")
    }

    private func drainCallbacks() async {
        let drained = expectation(description: "Earlier main-queue callbacks delivered")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
    }

    private static let finalToken = #"{"tokens":[{"text":"Hello","start_ms":0,"end_ms":100,"speaker":"1","confidence":0.99,"is_final":true}]}"#

    /// The socket hands this test's events to the client queue. `@unchecked
    /// Sendable`: the test only reads `socket`, which never changes.
    private final class SocketBox: @unchecked Sendable {
        let socket: WebSocket
        init(_ socket: WebSocket) { self.socket = socket }
    }

    /// Frames are decoded on the client's own serial queue, not on main
    /// (2026-11-13 M1 audit), and their words still reach main in order.
    func test_framesDecodeOffMainAndKeepTheirOrder() async throws {
        let client = SonioxClient(apiKey: "test", url: unreachable)
        let box = SocketBox(makeSocket())
        client.adoptSocketForTesting(box.socket)
        defer { client.disconnect() }
        XCTAssertTrue(box.socket.callbackQueue === client.callbackQueue)
        XCTAssertFalse(box.socket.callbackQueue === DispatchQueue.main)
        var words: [String] = []
        var allOnMain = true
        client.onWords = { batch in
            allOnMain = allOnMain && Thread.isMainThread
            words += batch.map(\.text)
        }
        let decodedOffMain = expectation(description: "decoded off main")
        decodedOffMain.expectedFulfillmentCount = 40
        for index in 0..<40 {
            let frame = #"{"tokens":[{"text":"w\#(index)","start_ms":\#(index * 100),"end_ms":\#(index * 100 + 90),"confidence":0.9,"is_final":true}]}"#
            client.callbackQueue.async {
                let offMain = !Thread.isMainThread
                client.didReceive(event: .text(frame), client: box.socket)
                if offMain { decodedOffMain.fulfill() }
            }
        }
        await fulfillment(of: [decodedOffMain], timeout: 2)
        await drainCallbacks()
        XCTAssertEqual(words, (0..<40).map { "w\($0)" })
        XCTAssertTrue(allOnMain, "words are delivered on main")
    }
}
