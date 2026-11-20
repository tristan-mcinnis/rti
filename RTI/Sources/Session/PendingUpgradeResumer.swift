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
    private var retryTask: Task<Void, Never>?
    private var retryAttempt = 0

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

    /// Try the queue again later. A Soniox upload that drops while the Mac
    /// stays online never trips the network monitor (2026-11-18: the upgrade
    /// waited 19 hours for the next launch). Waits 10, 30, then 60 minutes,
    /// and every hour after while something stays queued.
    func scheduleRetry() {
        retryTask?.cancel()
        let delay = PendingUpgradeRetry.delay(afterAttempt: retryAttempt)
        retryAttempt += 1
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.resume(reason: "retry timer")
        }
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
        guard !pending.isEmpty else {
            retryAttempt = 0
            return
        }
        RTILog.log("resuming \(pending.count) pending transcript upgrade(s) (\(reason))", category: .archive)
        var stillQueued = false
        defer {
            if stillQueued { scheduleRetry() } else { retryAttempt = 0 }
        }
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
                stillQueued = stillQueued || TranscriptUpgradeService.isRetryable(error)
                RTILog.log("pending transcript upgrade remains queued for \(session.url.lastPathComponent): \(error.localizedDescription)", category: .archive)
            }
        }
    }
}
