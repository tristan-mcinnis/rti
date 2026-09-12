import Darwin
import Foundation

/// The control socket: a deliberately dumb listener on a background thread.
///
/// It parses one word, answers `status` from its own snapshot, resolves
/// `toggle` against that snapshot, and hands a concrete verb to a closure. No
/// audio, no models, no main-actor wait — nothing on RTI's critical path. If
/// the socket cannot be bound the app logs and carries on: losing remote
/// control must never cost a recording.
public final class ControlSocketServer: @unchecked Sendable {

    /// `lock` guards `snapshot`, `listenFD` and `socketPath`. Everything else
    /// is immutable after `init`, and the accept thread touches nothing but
    /// these three through their accessors.
    private let lock = NSLock()
    private var snapshot = ControlSnapshot.idle
    private var listenFD: Int32 = -1
    private var socketPath: String?

    private let app: String
    private let dispatch: @Sendable (ControlVerb) -> Void
    private let log: @Sendable (String) -> Void

    /// A request is a word; anything longer than this is not one, and reading
    /// stops rather than growing a buffer for a client that never sends a
    /// newline.
    private static let maxLineBytes = 256
    /// `sockaddr_un.sun_path` is 104 bytes including the terminator.
    private static let maxPathBytes = 103

    public init(
        app: String = ControlManifest.appID,
        log: @escaping @Sendable (String) -> Void = { _ in },
        dispatch: @escaping @Sendable (ControlVerb) -> Void
    ) {
        self.app = app
        self.log = log
        self.dispatch = dispatch
    }

    // MARK: - State mirror

    /// Publish the live session state. Called from the main actor on every
    /// phase change; the socket thread only reads it.
    public func update(_ snapshot: ControlSnapshot) {
        lock.lock()
        self.snapshot = snapshot
        lock.unlock()
    }

    public func currentSnapshot() -> ControlSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    // MARK: - Protocol

    /// One request line in, one reply line out (without its newline). Pure
    /// apart from `dispatch`, so the whole protocol is testable without a
    /// socket.
    ///
    /// Action verbs are dispatched and acknowledged immediately rather than
    /// waited on: the contract says a command never blocks longer than a
    /// second, and every entry point on the app side guards its own phase, so
    /// a `stop` while idle is a no-op that still replies success.
    public func reply(to line: String, at now: Date = Date()) -> String {
        guard let verb = ControlVerb.parse(line) else { return "error unknown verb" }
        let snapshot = currentSnapshot()
        if verb == .status { return snapshot.statusLine(app: app, at: now) }
        let resolved = verb.resolved(recording: snapshot.recording)
        dispatch(resolved)
        return "ok \(resolved.rawValue)"
    }

    // MARK: - Listener

    /// Bind and start accepting. Returns whether the socket came up; a false
    /// return is logged and otherwise ignored by the caller, by design.
    @discardableResult
    public func start(at url: URL) -> Bool {
        let path = url.path
        let pathBytes = Array(path.utf8)
        guard pathBytes.count <= Self.maxPathBytes else {
            log("control socket unavailable: path too long (\(pathBytes.count) bytes) at \(path)")
            return false
        }

        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // A leftover socket file from a crashed run blocks bind(); clear it
        // first. RTI refuses to run twice (AppDelegate.ensureSingleInstance),
        // so a stale path is always genuinely stale.
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            log("control socket unavailable: socket() failed (errno \(errno))")
            return false
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            log("control socket unavailable at \(path) (bind errno \(errno)) — RTI runs normally")
            close(fd)
            return false
        }

        // Callable by this user only. A URL scheme would be one stray click
        // from any web page; a 0600 socket in the user's own directory is not.
        chmod(path, 0o600)

        guard listen(fd, 8) == 0 else {
            log("control socket unavailable at \(path) (listen errno \(errno)) — RTI runs normally")
            close(fd)
            unlink(path)
            return false
        }

        lock.lock()
        listenFD = fd
        socketPath = path
        lock.unlock()

        let thread = Thread { [weak self] in self?.acceptLoop(listener: fd) }
        thread.name = "rti.control"
        thread.qualityOfService = .utility
        thread.start()
        return true
    }

    /// Close the listener and remove the socket file.
    public func stop() {
        lock.lock()
        let fd = listenFD
        let path = socketPath
        listenFD = -1
        socketPath = nil
        lock.unlock()

        if fd >= 0 { close(fd) }
        if let path { unlink(path) }
    }

    private func acceptLoop(listener: Int32) {
        while true {
            let client = accept(listener, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return // listener closed by stop(), or a hard error: stand down quietly
            }
            serve(connection: client)
            close(client)
        }
    }

    private func serve(connection fd: Int32) {
        // A client that connects and says nothing must not pin this thread,
        // and one that hangs up before reading its reply must not raise
        // SIGPIPE and take the app down with it.
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))

        var request = [UInt8]()
        var byte: UInt8 = 0
        while request.count < Self.maxLineBytes {
            let count = read(fd, &byte, 1)
            if count <= 0 { break }
            if byte == UInt8(ascii: "\n") { break }
            request.append(byte)
        }

        let line = String(decoding: request, as: UTF8.self)
        var reply = self.reply(to: line)
        reply.append("\n")
        let bytes = Array(reply.utf8)
        bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var sent = 0
            while sent < buffer.count {
                let written = write(fd, base + sent, buffer.count - sent)
                if written <= 0 { return }
                sent += written
            }
        }
    }
}
