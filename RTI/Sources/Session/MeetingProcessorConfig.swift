import Foundation

/// Config policy for the unattended `/meeting` run that RTI can start with
/// `claude -p` after a session. Both switches default to off.
enum MeetingProcessorConfig {
    /// The run is opt-in: `auto_process` must be `true` in the config file.
    /// Absent or any other value means off.
    static func isEnabled(config: [String: Any]) -> Bool {
        (config["auto_process"] as? Bool) ?? false
    }

    /// Permission flags for the run. The default is the safer `acceptEdits`
    /// mode; `auto_process_yolo: true` opts in to skipping every prompt.
    static func permissionArguments(config: [String: Any]) -> [String] {
        let yolo = (config["auto_process_yolo"] as? Bool) ?? false
        return yolo
            ? ["--dangerously-skip-permissions"]
            : ["--permission-mode", "acceptEdits"]
    }
}
