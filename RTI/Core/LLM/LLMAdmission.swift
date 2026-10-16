import Foundation

/// Scheduling priority for one LLM request.
///
/// The live surface (a chat turn the user is waiting on) is `foreground`; the
/// deferred work (end-of-session summary, generated title, live analysis tick,
/// saved-meeting output recipe) is `background`. Only the *scheduler* treats
/// them differently — both still run on the same provider client.
public enum LLMPriority: Sendable, Equatable {
    /// A request the user is waiting on right now. Never waits.
    case foreground
    /// A deferred or periodic request. Waits for foreground to settle, and
    /// yields when foreground work arrives.
    case background
}

/// A held admission slot. Release it when the request ends. A foreground lease
/// keeps background work waiting or yielding until it is released.
public struct LLMLease: Sendable, Equatable {
    public let id: UUID
    public let priority: LLMPriority

    public init(id: UUID = UUID(), priority: LLMPriority) {
        self.id = id
        self.priority = priority
    }
}

/// One-shot, idempotent continuation holder.
///
/// A background waiter is resumed from two possible places: the scheduler
/// (foreground settled) and the task's own cancellation handler (the caller
/// went away). Both may race, so the first `resume()` wins and every later
/// call is a no-op. `lock` guards the only state; nothing else touches it.
private final class AdmissionWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var isResumed = false

    func install(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        if isResumed {
            lock.unlock()
            continuation.resume()
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resume() {
        lock.lock()
        guard !isResumed else {
            lock.unlock()
            return
        }
        isResumed = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}

/// A held background admission: the lease plus the foreground epoch observed
/// at the instant the slot opened. Both are captured inside the actor, so the
/// caller cannot race a foreground acquisition between "no foreground" and
/// "which epoch to watch".
public struct LLMBackgroundAdmission: Sendable {
    public let lease: LLMLease
    public let epoch: UInt64

    public init(lease: LLMLease, epoch: UInt64) {
        self.lease = lease
        self.epoch = epoch
    }
}

/// The admission policy that gives interactive LLM work real priority over
/// background work.
///
/// The rule is intentionally small and fully testable:
///
/// * `acquireForeground()` never waits — a live request is admitted the moment
///   it arrives and bumps the foreground epoch.
/// * `acquireBackground()` returns only while no foreground work is active.
///   A queued background caller suspends and is woken when foreground settles;
///   if foreground is still active it re-suspends, so foreground never queues
///   behind background.
/// * `waitForForegroundChange(after:)` lets an *in-flight* background request
///   notice a foreground arrival and yield (the caller cancels the provider
///   stream and retries once foreground settles).
///
/// The controller is a pure gate: it never cancels a task itself, never drops
/// work, and holds no reference to a request. Cancelling a queued background
/// task wakes it immediately (via the cancellation handler) and leaves the
/// scheduler healthy — no leaked waiter, no leaked permit.
public actor LLMAdmissionController {
    public static let shared = LLMAdmissionController()

    /// The ids of every foreground lease currently held. A Set (not a bare
    /// count) so releasing the same lease twice is a no-op and can never
    /// wrongly unblock background work while another foreground lease is live.
    private var foregroundLeases: Set<UUID> = []
    /// Bumped on every foreground acquisition. A background run captures the
    /// epoch when it starts and yields when the epoch moves.
    private var foregroundEpoch: UInt64 = 0
    private var backgroundWaiters: [UUID: AdmissionWaiter] = [:]
    private var epochWaiters: [UUID: AdmissionWaiter] = [:]

    public init() {}

    /// True while at least one foreground request holds a slot.
    public var foregroundActive: Bool { !foregroundLeases.isEmpty }

    /// The value a background run captures before racing `waitForForegroundChange`.
    public var currentForegroundEpoch: UInt64 { foregroundEpoch }

    // MARK: - Foreground

    /// Admit a foreground request. Never suspends.
    public func acquireForeground() -> LLMLease {
        let lease = LLMLease(priority: .foreground)
        foregroundLeases.insert(lease.id)
        foregroundEpoch &+= 1
        // Wake every epoch waiter so an in-flight background run can yield.
        let waiters = epochWaiters
        epochWaiters.removeAll()
        for waiter in waiters.values { waiter.resume() }
        return lease
    }

    /// Release a foreground request. Idempotent: a repeated release of the same
    /// lease does nothing (it cannot decrement another request's slot). When the
    /// last live lease ends, wake the queued background callers.
    public func releaseForeground(_ lease: LLMLease) {
        guard lease.priority == .foreground else { return }
        guard foregroundLeases.remove(lease.id) != nil else { return }
        guard foregroundLeases.isEmpty else { return }
        wakeBackground()
    }

    // MARK: - Background

    /// Admit a background request once no foreground work is active. Returns
    /// nil only when the calling task is cancelled before a slot opens. The
    /// slot and the foreground epoch are captured together.
    public func acquireBackground() async -> LLMBackgroundAdmission? {
        while !foregroundLeases.isEmpty {
            await suspendBackground()
            if Task.isCancelled { return nil }
        }
        if Task.isCancelled { return nil }
        return LLMBackgroundAdmission(lease: LLMLease(priority: .background), epoch: foregroundEpoch)
    }

    /// Background leases gate admission only; there is no resource to hand back.
    public func releaseBackground(_ lease: LLMLease) {
        _ = lease
    }

    /// Suspend until new foreground work starts (the epoch moves past `epoch`).
    /// Used to preempt an in-flight background run.
    public func waitForForegroundChange(after epoch: UInt64) async {
        if foregroundEpoch != epoch { return }
        await suspendEpoch(after: epoch)
    }

    // MARK: - Wait suspension

    private func wakeBackground() {
        let waiters = backgroundWaiters
        backgroundWaiters.removeAll()
        for waiter in waiters.values { waiter.resume() }
    }

    private func suspendBackground() async {
        let id = UUID()
        let waiter = AdmissionWaiter()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if Task.isCancelled {
                    continuation.resume()
                    return
                }
                waiter.install(continuation)
                backgroundWaiters[id] = waiter
            }
        } onCancel: {
            // No actor hop and no new Task: the waiter is thread-safe and the
            // first resume wins either here or in wakeBackground().
            waiter.resume()
        }
        backgroundWaiters[id] = nil
    }

    private func suspendEpoch(after epoch: UInt64) async {
        let id = UUID()
        let waiter = AdmissionWaiter()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if Task.isCancelled {
                    continuation.resume()
                    return
                }
                waiter.install(continuation)
                epochWaiters[id] = waiter
            }
        } onCancel: {
            waiter.resume()
        }
        epochWaiters[id] = nil
    }
}
