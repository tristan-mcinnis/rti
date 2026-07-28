import Darwin
import Foundation
import Observation

/// A meeting that the external "Meeting Sentinel" tool (`meet start`/`meet stop`,
/// `~/.local/bin/meet` → `meeting-stack/meeting-sentinel/meet.py`) is currently recording.
struct SentinelMeeting: Equatable {
    let name: String
    let startedAt: Date
    let audioFilePath: String

    var elapsed: TimeInterval { max(0, Date().timeIntervalSince(startedAt)) }
}

/// Step 1 of the RTI ⇄ Meeting Sentinel bridge: RTI is a *follower*. Sentinel
/// owns recording and the accurate post-meeting transcript; RTI just needs to
/// know when a meeting is live so it can overlay live intelligence.
///
/// Sentinel writes `~/.config/meeting-sentinel/state.json` on `meet start` and
/// deletes it on `meet stop`. We poll that file (no changes to meet.py) and,
/// guarding against stale state left by a crash, expose the live meeting.
@Observable @MainActor
final class MeetingSentinelMonitor {
    static let shared = MeetingSentinelMonitor()

    /// Non-nil while Sentinel is actively recording a meeting.
    private(set) var liveMeeting: SentinelMeeting?

    private var timer: Timer?
    private let stateURL: URL

    private init() {
        stateURL = SentinelPaths.stateURL()
    }

    func start() {
        guard timer == nil else { return }
        poll()
        let timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        self.timer = timer
    }

    private func poll() {
        liveMeeting = readLiveMeeting()
    }

    private func readLiveMeeting() -> SentinelMeeting? {
        guard let data = try? Data(contentsOf: stateURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = obj["pid"] as? Int,
              let name = obj["name"] as? String,
              let audioFile = obj["audio_file"] as? String,
              let startedAtRaw = obj["started_at"] as? String
        else { return nil }

        // Stale-state guard: meet.py can leave state.json behind if ffmpeg
        // dies without `meet stop`. Treat a dead pid as "no meeting".
        guard processAlive(pid) else { return nil }

        return SentinelMeeting(
            name: name,
            startedAt: Self.parseTimestamp(startedAtRaw) ?? Date(),
            audioFilePath: audioFile
        )
    }

    /// kill(pid, 0) probes existence without signalling. ESRCH ⇒ gone;
    /// EPERM ⇒ exists but not ours (still "alive" for our purposes).
    private func processAlive(_ pid: Int) -> Bool {
        if kill(pid_t(pid), 0) == 0 { return true }
        return errno == EPERM
    }

    /// meet.py writes `datetime.now().isoformat()` — local time, no zone,
    /// optional fractional seconds (e.g. "2026-05-26T22:02:11.123456").
    /// Parse the seconds-precision prefix in the local zone; fractional
    /// seconds don't matter for an elapsed display.
    private static func parseTimestamp(_ raw: String) -> Date? {
        let trimmed = String(raw.split(separator: ".").first ?? Substring(raw))
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.date(from: trimmed)
    }
}
