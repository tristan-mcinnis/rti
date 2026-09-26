import Foundation

/// A small, invented vault for render proofs, so no proof reads the real
/// vault or real meetings.
///
/// `install()` writes it once per test process into a fresh temporary
/// folder, then points `RTI_CONFIG_HOME` at a config whose `recordings_dir`
/// sits inside it. `VaultPaths` is RTI's single path authority, so the
/// Sessions browser, `SessionArchive.recentSessions`, the workstream picker,
/// and the vault tools all resolve into this tree for the rest of the run.
///
/// Layout (the shape `SessionArchive` and the meeting processor write):
///
///     <root>/config/config.json
///     <root>/kb/databases/projects/personal/rti/sessions/<yyyy-MM-dd HHmmss>/…
///     <root>/kb/databases/projects/northwind/onboarding-brief.md
///     <root>/kb/databases/meetings/<yyyyMMdd>-<slug>.md          (meeting notes)
///     <root>/kb/databases/meetings/recordings/<stem>.meeting.json (legacy sidecar)
///     <root>/kb/databases/meetings/transcripts-raw/<stem>-transcript.txt
///
/// The sessions cover every title source the Sessions window resolves:
/// a summary title, a manual title, a vault meeting note that names the
/// session (`source: rti-session-<stamp>`), notes with no title, a short
/// test, and a legacy recorded meeting. Days are counted back from the day
/// the proof runs, so the date groups (Today, This week, Earlier) all fill.
@MainActor
enum FixtureVault {
    /// One archived RTI session folder.
    struct Session {
        /// Days before the run day (0 = today).
        let daysAgo: Int
        let hour: Int
        let minute: Int
        let durationSeconds: Int
        /// `title.txt`; nil models a failed summary call.
        let title: String?
        /// Also writes `title-manual.txt` (the user edited the title).
        var manualTitle = false
        var mode: String? = "Meeting"
        var workstream: String?
        /// File name → body (frontmatter is added for `.md` files).
        let files: [String: String]
    }

    /// A vault meeting note that names an RTI session in its frontmatter.
    struct MeetingNote {
        let session: Int // index into `sessions`
        let slug: String
        let title: String
    }

    static let sessions: [Session] = [
        Session(
            daysAgo: 0, hour: 15, minute: 0, durationSeconds: 16 * 60,
            title: "Pricing page teardown", manualTitle: true, workstream: "Northwind app",
            files: [
                "transcript.md": transcript([
                    ("Speaker 1", "0:04", "Let's go through the pricing page top to bottom. The plan table is doing too much."),
                    ("Speaker 2", "0:19", "Agreed. Three tiers, one highlighted, and move the FAQ under the table."),
                ]),
                "notes.md": notes([
                    ("0:00 – 8:00", "Plan table", "- Cut to three tiers.\n- Highlight the middle tier."),
                    ("8:00 – 16:00", "FAQ placement", "- Move the FAQ under the table."),
                ]),
            ]
        ),
        Session(
            daysAgo: 0, hour: 10, minute: 30, durationSeconds: 34 * 60,
            title: "Onboarding Scope Review with Northwind", workstream: "Northwind app",
            files: [
                "summary.md": "# Meeting summary\n\n"
                    + "The team dropped the guided tour from the first release and will measure first-screen drop-off instead.\n\n"
                    + "## Decisions\n\n- Ship without the guided tour.\n- Speaker 2 writes the decision note for design.\n\n"
                    + "## Open questions\n\n- Who sets the drop-off threshold that brings the tour back?\n",
                "transcript.md": transcript([
                    ("Speaker 1", "12:03", "So the main thing we need to lock this week is the onboarding scope. If we keep the guided tour, the launch slips by a sprint."),
                    ("Speaker 2", "12:21", "I'd rather ship without the tour and measure drop-off on the first screen. We can add it back in point-one if the numbers say so."),
                    ("Speaker 1", "12:38", "Fine by me. Can you own the decision note so design isn't surprised on Thursday?"),
                    ("Speaker 1", "12:44", "I'll put the drop-off numbers on the agenda for next week."),
                    ("📝 Note", "12:50", "Decision note owner: Speaker 2"),
                ]),
                "notes.md": notes([
                    ("0:00 – 12:00", "Launch timing", "- The guided tour costs a sprint."),
                    ("12:00 – 24:00", "Guided tour decision", "- Ship without it; measure first-screen drop-off."),
                ]),
                "chat.md": "# Chat\n\n**You** _(Assist, transcript)_\n\nAssist\n\n"
                    + "**Assistant**\n\nThey've just agreed to drop the guided tour and measure first-screen drop-off instead.\n",
            ]
        ),
        Session(
            daysAgo: 2, hour: 9, minute: 15, durationSeconds: 48 * 60,
            title: nil, mode: "Interview", workstream: "Fabrikam",
            files: [
                "transcript.md": transcript([
                    ("Speaker 1", "3:10", "How often do you use the loyalty card when you buy coffee?"),
                    ("Speaker 2", "3:22", "Most mornings. I stopped when the app asked me to sign in again every week."),
                ]),
                "notes.md": notes([
                    ("0:00 – 16:00", "Card habits", "- Uses the card most mornings."),
                    ("16:00 – 32:00", "Sign-in friction", "- Weekly sign-in made them stop."),
                ]),
            ]
        ),
        Session(
            daysAgo: 5, hour: 14, minute: 0, durationSeconds: 16 * 60,
            title: nil, workstream: "Contoso retail",
            files: [
                "transcript.md": transcript([
                    ("Speaker 1", "0:40", "The store map needs one change before the pilot: the pickup counter moves to the front."),
                ]),
                "notes.md": notes([
                    ("0:00 – 8:00", "Store map pilot", "- Pickup counter moves to the front."),
                    ("8:00 – 16:00", "Staff rota", "- Two people on the counter at opening."),
                ]),
            ]
        ),
        Session(
            daysAgo: 12, hour: 11, minute: 5, durationSeconds: 12,
            title: nil, mode: nil,
            files: [
                "transcript.md": transcript([
                    ("Speaker 1", "0:02", "Testing, one two."),
                ]),
            ]
        ),
    ]

    static let meetingNotes: [MeetingNote] = [
        MeetingNote(session: 2, slug: "fabrikam-loyalty-research", title: "Fabrikam loyalty card research debrief"),
    ]

    /// The legacy recorded meeting (a `.meeting.json` sidecar, no RTI folder).
    static let recordedMeeting = (daysAgo: 20, hour: 14, minute: 0, name: "Quarterly planning sync")

    // MARK: - Install

    /// The fixture root after `install()`; nil before.
    private(set) static var root: URL?

    /// Folder of the archived sessions inside the fixture vault.
    static var sessionsDirectory: URL? {
        root?.appendingPathComponent("kb/databases/projects/personal/rti/sessions", isDirectory: true)
    }

    /// Write the fixture vault (once per process) and point RTI at it.
    static func install(now: Date = Date()) throws {
        if let root {
            setenv("RTI_CONFIG_HOME", root.appendingPathComponent("config").path, 1)
            return
        }
        let fm = FileManager.default
        let base = fm.temporaryDirectory
            .appendingPathComponent("rti-render-fixture-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? fm.removeItem(at: base)

        let databases = base.appendingPathComponent("kb/databases", isDirectory: true)
        let recordings = databases.appendingPathComponent("meetings/recordings", isDirectory: true)
        let transcriptsRaw = databases.appendingPathComponent("meetings/transcripts-raw", isDirectory: true)
        let sessionsDir = databases.appendingPathComponent("projects/personal/rti/sessions", isDirectory: true)
        let project = databases.appendingPathComponent("projects/northwind", isDirectory: true)
        for dir in [recordings, transcriptsRaw, sessionsDir, project] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        // Config: `recordings_dir` anchors the whole tree (VaultPaths).
        let configHome = base.appendingPathComponent("config", isDirectory: true)
        try fm.createDirectory(at: configHome, withIntermediateDirectories: true)
        let config = try JSONSerialization.data(withJSONObject: ["recordings_dir": recordings.path], options: [.sortedKeys])
        try config.write(to: configHome.appendingPathComponent("config.json"))

        try write(
            frontmatter(title: "Onboarding brief", date: now) + "# Onboarding brief\n\nFirst release: no guided tour. Measure first-screen drop-off.\n",
            to: project.appendingPathComponent("onboarding-brief.md")
        )

        // Archived RTI sessions.
        var stamps: [Date] = []
        for session in sessions {
            let startedAt = time(daysAgo: session.daysAgo, hour: session.hour, minute: session.minute, from: now)
            stamps.append(startedAt)
            let dir = sessionsDir.appendingPathComponent(folderStamp.string(from: startedAt), isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for (name, body) in session.files {
                let kind = name.replacingOccurrences(of: ".md", with: "").replacingOccurrences(of: "-", with: " ").capitalized
                let text = name.hasSuffix(".md")
                    ? frontmatter(title: "RTI session · \(frontmatterStamp.string(from: startedAt)) · \(kind)", date: startedAt) + body
                    : body
                try write(text, to: dir.appendingPathComponent(name))
            }
            if let title = session.title {
                try write(title, to: dir.appendingPathComponent("title.txt"))
            }
            if session.manualTitle {
                try write("", to: dir.appendingPathComponent("title-manual.txt"))
            }
            var metadata: [String: Any] = [
                "sessionId": "fixture-\(folderStamp.string(from: startedAt))",
                "durationSeconds": session.durationSeconds,
            ]
            metadata["mode"] = session.mode
            metadata["workstream"] = session.workstream
            let json = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
            try json.write(to: dir.appendingPathComponent("session.json"))
        }

        // Vault meeting notes that name a session (the meeting processor's shape).
        let meetings = databases.appendingPathComponent("meetings", isDirectory: true)
        for note in meetingNotes {
            let startedAt = stamps[note.session]
            let body = """
            ---
            title: "\(note.title)"
            type: meeting
            date: \(dayStamp.string(from: startedAt))
            source: rti-session-\(canonicalStamp.string(from: startedAt))
            ---
            # \(note.title)

            Invented fixture note for render proofs.

            """
            try write(body, to: meetings.appendingPathComponent("\(compactDay.string(from: startedAt))-\(note.slug).md"))
        }

        // One legacy recorded meeting: a transcribed sidecar and its transcript.
        let meetingStart = time(
            daysAgo: recordedMeeting.daysAgo, hour: recordedMeeting.hour, minute: recordedMeeting.minute, from: now
        )
        let stem = canonicalStamp.string(from: meetingStart)
        let legacyTranscript = transcriptsRaw.appendingPathComponent("\(stem)-transcript.txt")
        try write("Speaker 1: Let's agree the three goals for next quarter.\n", to: legacyTranscript)
        let sidecar: [String: Any] = [
            "name": recordedMeeting.name,
            "started_at": sidecarStamp.string(from: meetingStart),
            "status": "transcribed",
            "transcript_file": legacyTranscript.path,
        ]
        try JSONSerialization.data(withJSONObject: sidecar, options: [.sortedKeys])
            .write(to: recordings.appendingPathComponent("\(stem).meeting.json"))

        root = base
        setenv("RTI_CONFIG_HOME", configHome.path, 1)
    }

    // MARK: - Writers

    private static func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func frontmatter(title: String, date: Date) -> String {
        """
        ---
        title: "\(title)"
        type: reference
        date: \(dayStamp.string(from: date))
        source: rti
        projects:
          - rti
        tags:
          - rti
        ---

        """
    }

    /// `transcript.md` body: "`m:ss` **Speaker:** text" paragraphs.
    private static func transcript(_ turns: [(speaker: String, offset: String, text: String)]) -> String {
        "# Transcript\n\n" + turns.map { "`\($0.offset)` **\($0.speaker):** \($0.text)\n" }.joined(separator: "\n")
    }

    /// `notes.md` body: one "### start – end · title" block per slice.
    private static func notes(_ slices: [(range: String, title: String, body: String)]) -> String {
        "# Notes\n\n" + slices.map { "### \($0.range) · \($0.title)\n\n\($0.body)\n" }.joined(separator: "\n")
    }

    private static func time(daysAgo: Int, hour: Int, minute: Int, from now: Date) -> Date {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: now)) ?? now
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }

    // MARK: - Stamps (the formats SessionArchive and VaultPaths parse)

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }

    private static let folderStamp = formatter("yyyy-MM-dd HHmmss")
    private static let canonicalStamp = formatter("yyyyMMdd-HHmmss")
    private static let compactDay = formatter("yyyyMMdd")
    private static let dayStamp = formatter("yyyy-MM-dd")
    private static let frontmatterStamp = formatter("yyyy-MM-dd HH:mm")
    private static let sidecarStamp = formatter("yyyy-MM-dd'T'HH:mm:ss.SSSSSS")
}
