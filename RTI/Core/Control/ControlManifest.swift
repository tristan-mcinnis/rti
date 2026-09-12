import Foundation

/// One command RTI publishes to the house launcher.
public struct ControlCommand: Equatable, Sendable {
    public let id: String
    /// A user-visible string, sentence case, naming the effect.
    public let title: String
    public let verb: ControlVerb
    /// `nil`, `"text"` or `"choice"` when the command takes one argument.
    public let needs: String?
    /// A boolean field of the status document, optionally negated with `!`.
    public let unavailableWhen: String?

    public init(id: String, title: String, verb: ControlVerb, needs: String? = nil, unavailableWhen: String? = nil) {
        self.id = id
        self.title = title
        self.verb = verb
        self.needs = needs
        self.unavailableWhen = unavailableWhen
    }
}

/// RTI's manifest — what the app can be told to do, written at launch to
/// `~/Library/Application Support/House/commands/rti.json` per
/// `design-system/docs/app-commands.md`.
///
/// Nothing here destroys data. Deleting, clearing and overwriting a session
/// stay inside RTI's own UI, which is the contract's safety rule; `sessions`
/// only opens the browser window.
public enum ControlManifest {
    public static let schema = 1
    public static let appID = "rti"
    public static let appName = "RTI"
    public static let transport = "socket"
    public static let statusVerb = ControlVerb.status

    /// `pause` is offered whenever the app is not already paused: while idle it
    /// is a harmless no-op. The status document carries only the two booleans
    /// the contract names for RTI (`recording`, `paused`), and one clause per
    /// command cannot say "recording AND not paused" — a no-op beats inventing
    /// a field the contract does not describe.
    public static let commands: [ControlCommand] = [
        ControlCommand(id: "record.start", title: "Start Recording", verb: .start, unavailableWhen: "recording"),
        ControlCommand(id: "record.stop", title: "Stop Recording", verb: .stop, unavailableWhen: "!recording"),
        ControlCommand(id: "record.pause", title: "Pause Recording", verb: .pause, unavailableWhen: "paused"),
        ControlCommand(id: "record.resume", title: "Resume Recording", verb: .resume, unavailableWhen: "!paused"),
        ControlCommand(id: "sessions.open", title: "Open Sessions", verb: .sessions),
    ]

    /// The manifest document. `endpoint` is written as an absolute path: a
    /// reader that expands tildes and one that does not both resolve it.
    public static func document(socketPath: String) -> [String: Any] {
        [
            "schema": schema,
            "app": appID,
            "name": appName,
            "transport": transport,
            "endpoint": socketPath,
            "status": statusVerb.rawValue,
            "commands": commands.map { command in
                [
                    "id": command.id,
                    "title": command.title,
                    "verb": command.verb.rawValue,
                    "needs": command.needs as Any? ?? NSNull(),
                    "unavailableWhen": command.unavailableWhen as Any? ?? NSNull(),
                ] as [String: Any]
            },
        ]
    }

    /// Serialized for writing. Sorted keys keep the file byte-stable between
    /// launches, so a rewrite that changes nothing changes no bytes; slashes
    /// are left unescaped so the endpoint path is readable by eye.
    public static func json(socketPath: String) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: document(socketPath: socketPath),
            options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        )
    }
}
