import AppKit
import Foundation
import RTICore

/// RTI's side of the house command contract
/// (`design-system/docs/app-commands.md`): a control socket at
/// `~/.config/rti/control.sock` and a manifest telling Quick Launch what can be
/// asked for.
///
/// The listener never waits on the main actor. `status` is answered from a
/// snapshot this class publishes on every phase change; an action verb is
/// handed to the main actor and acknowledged straight away. If the socket
/// cannot be bound, that is logged and nothing else changes — remote control is
/// never worth a lost recording.
@MainActor
final class ControlService {
    static let shared = ControlService()

    private var started = false

    private lazy var server = ControlSocketServer(
        log: { message in RTILog.log(message, category: .general) },
        dispatch: { verb in
            Task { @MainActor in ControlService.perform(verb) }
        }
    )

    func start() {
        guard !started else { return }
        started = true

        let socket = ControlPaths.socketURL(configHome: VaultPaths.homeDirectory())
        if server.start(at: socket) {
            RTILog.log("control socket listening at \(socket.path)")
        }
        writeManifest(socketPath: socket.path)
        publish()
    }

    func stop() {
        guard started else { return }
        server.stop()
        started = false
    }

    /// Mirror the live session state into the listener. Driven by AppDelegate's
    /// phase observation, so it costs a wakeup only when something changed —
    /// the elapsed readout is a clock in the snapshot, not a ticking string.
    func publish() {
        let session = SessionCoordinator.shared
        let now = Date()
        server.update(
            ControlSnapshot.forSession(phase: session.phase, elapsed: session.elapsed(at: now), now: now)
        )
    }

    /// Run one resolved verb. Every entry point guards its own phase, so a
    /// command that arrives at the wrong moment is a no-op — which is exactly
    /// the contract's idempotency rule, without a second layer of checks here.
    private static func perform(_ verb: ControlVerb) {
        let session = SessionCoordinator.shared
        switch verb {
        case .start:
            session.startSession(userInitiated: true)
        case .stop:
            session.stopSession()
        case .pause:
            session.pause()
        case .resume:
            session.resume()
        case .sessions:
            RTIActivation.activateApp()
            WindowCoordinator.shared.showSessions()
        case .toggle, .status:
            // `toggle` is resolved and `status` answered inside the listener;
            // neither is ever dispatched.
            break
        }
    }

    private func writeManifest(socketPath: String) {
        guard let base = AppSupportPaths.applicationSupportBase() else { return }
        let url = ControlPaths.manifestURL(applicationSupport: base)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try ControlManifest.json(socketPath: socketPath).write(to: url, options: .atomic)
        } catch {
            RTILog.log("command manifest not written: \(error.localizedDescription)")
        }
    }
}
