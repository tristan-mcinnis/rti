import Foundation
import Network
import RTICore

/// Runs the automatic transcript upgrades that are still queued
/// (`automatic-upgrade.pending`): once at launch and again each time the
/// network comes back, so a call stopped during an outage reaches `/meeting`
/// without a relaunch. Runs never overlap; a request during a run queues one
/// more run.
@MainActor
final class PendingUpgradeResumer {
    static let shared = PendingUpgradeResumer()

    private var running = false
    private var rerun = false
    private var gate = NetworkReturnGate()
    private var monitor: NWPathMonitor?

    /// Resume now and on every return of the network.
    func start() {
        resume(reason: "launch")
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            let available = path.status == .satisfied
            Task { @MainActor in PendingUpgradeResumer.shared.networkChanged(available: available) }
        }
        monitor.start(queue: DispatchQueue(label: "rti.pending-upgrade.network", qos: .utility))
        self.monitor = monitor
    }

    func networkChanged(available: Bool) {
        if gate.update(available: available) {
            resume(reason: "network back")
        }
    }

    func resume(reason: String) {
        guard !running else {
            rerun = true
            return
        }
        running = true
        Task { @MainActor in
            repeat {
                rerun = false
                await runOnce(reason: reason)
            } while rerun
            running = false
        }
    }

    private func runOnce(reason: String) async {
        // The scan lists every session folder and legacy meeting sidecar;
        // keep that file walk off the main thread.
        let pending = await Task.detached(priority: .utility) {
            SessionArchive.pendingAutomaticUpgrades()
        }.value
        guard !pending.isEmpty else { return }
        RTILog.log("resuming \(pending.count) pending transcript upgrade(s) (\(reason))", category: .archive)
        for session in pending {
            // The live session's folder belongs to its own stop and upgrade.
            if SessionCoordinator.shared.ownsArchive(sessionStartedAt: session.date) {
                continue
            }
            do {
                _ = try await TranscriptUpgradeService.upgrade(
                    session: session,
                    provider: AsyncTranscriptProviders.soniox
                ) { _ in }
                SessionArchive.clearAutomaticUpgradePending(in: session.url)
            } catch let TranscriptUpgradeError.emptyTranscript(provider)
                where TranscriptUpgradeService.retainedAudioSeconds(in: session.url) < 60
            {
                // A sub-minute session that transcribes to nothing is a
                // test blip, not a meeting: stop re-queueing it forever.
                SessionArchive.clearAutomaticUpgradePending(in: session.url)
                RTILog.log("cleared pending upgrade for \(session.url.lastPathComponent): \(provider) returned an empty transcript and the retained audio is under a minute", category: .archive)
            } catch {
                RTILog.log("pending transcript upgrade remains queued for \(session.url.lastPathComponent): \(error.localizedDescription)", category: .archive)
            }
        }
    }
}
