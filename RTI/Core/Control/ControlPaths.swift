import Foundation

/// Where the control surface lives on disk.
///
/// The socket sits in the user's config directory, never `temp_dir()`: a
/// GUI-launched app and a CLI client resolve different `$TMPDIR` values and
/// would never meet at the same path. That lesson is already paid for in
/// local-dictation; it is not re-learned here.
///
/// Both resolvers take their base directory as an argument rather than
/// re-deriving it, so RTI keeps one resolver per location — `VaultPaths` owns
/// `~/.config/rti`, `AppSupportPaths` owns Application Support.
public enum ControlPaths {
    /// Overrides the socket path outright. Used by tests, which must never
    /// bind the real one.
    public static let socketEnvironmentKey = "RTI_CONTROL_SOCK"
    /// Overrides the directory the command manifest is written into.
    public static let manifestEnvironmentKey = "HOUSE_COMMANDS_DIR"

    public static let socketFileName = "control.sock"
    public static let manifestFileName = "rti.json"

    public static func socketURL(
        configHome: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment[socketEnvironmentKey], !override.trimmingCharacters(in: .whitespaces).isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return configHome.appendingPathComponent(socketFileName)
    }

    /// `<Application Support>/House/commands/rti.json` — the shared house
    /// directory, deliberately outside RTI's own folder.
    public static func manifestURL(
        applicationSupport: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment[manifestEnvironmentKey], !override.trimmingCharacters(in: .whitespaces).isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
                .appendingPathComponent(manifestFileName)
        }
        return applicationSupport
            .appendingPathComponent("House", isDirectory: true)
            .appendingPathComponent("commands", isDirectory: true)
            .appendingPathComponent(manifestFileName)
    }
}
