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
}
