import Foundation
import RTICore

/// Sample content shared by the render proofs. The first three sets match
/// the Claude Design mockup (`rti.dc.html`, direction 1b "Slate"), so the
/// PNGs can be compared with the tiles side by side. Everything here is
/// invented; no real person, client, or meeting.
@MainActor
enum RenderFixtures {
    // MARK: - Chat

    static var assistTurns: [ChatEntry] { [
        ChatEntry(role: "user", text: "Assist", action: "Assist", contextUsed: true, screenContextUsed: false),
        ChatEntry(
            role: "assistant",
            text: """
            They've just agreed to drop the guided tour and measure first-screen drop-off instead. \
            Speaker 2 is taking the decision note; design hasn't been told yet.

            Worth raising now: who defines the drop-off threshold that would bring the tour back, \
            and by when. That decides whether "point-one" is a real commitment.
            """,
            action: nil,
            contextUsed: false,
            screenContextUsed: false
        ),
    ] }

    /// One asked question with every turn record filled in: attachments on
    /// the question, tool lines and sources on the answer.
    static var turnsWithRecords: [ChatEntry] { [
        ChatEntry(
            role: "user",
            text: "What did we decide about the guided tour last time?",
            action: "Ask",
            contextUsed: true,
            screenContextUsed: true,
            referencedPaths: ["projects/northwind/onboarding-brief.md"],
            attachments: [
                ChatAttachmentRef(kind: .vaultFile, name: "onboarding-brief.md", path: "projects/northwind/onboarding-brief.md"),
                ChatAttachmentRef(kind: .pdf, name: "Launch plan.pdf", path: "/tmp/Launch plan.pdf", byteCount: 84_000, pageCount: 12),
                ChatAttachmentRef(kind: .text, name: "Survey export.txt", path: "/tmp/Survey export.txt", byteCount: 48_000, wasCut: true),
                ChatAttachmentRef(kind: .screen, name: "Screen"),
            ]
        ),
        ChatEntry(
            role: "assistant",
            text: """
            Last week the team kept the guided tour out of the first release. \
            It comes back only if first-screen drop-off passes the agreed threshold.
            """,
            action: nil,
            contextUsed: false,
            screenContextUsed: false,
            tools: [
                ChatToolLine(kind: .transcript, text: "Used the last 6 min of the transcript"),
                ChatToolLine(kind: .readScreen, text: "Read the screen"),
                ChatToolLine(kind: .searchVault, text: "Searched vault · 6 results"),
                ChatToolLine(kind: .readDocument, text: "Read onboarding-brief.md"),
            ],
            sources: [
                ChatSource(title: "Onboarding Scope Review with Northwind", path: "projects/personal/rti/sessions/northwind/summary.md", date: fixedDay(-7)),
                ChatSource(title: "Onboarding brief", path: "projects/northwind/onboarding-brief.md", date: fixedDay(-9)),
            ]
        ),
    ] }

    // MARK: - Transcript

    static var speakerTurns: [LiveEntry] { [
        liveEntry("them_1", "So the main thing we need to lock this week is the onboarding scope. If we keep the guided tour, the launch slips by a sprint.", 723_000),
        liveEntry("them_2", "I'd rather ship without the tour and measure drop-off on the first screen. We can add it back in point-one if the numbers say so.", 741_000),
        liveEntry("them_1", "Fine by me. Can you own the decision note so design isn't surprised on Thursday?", 758_000),
    ] }

    static func liveEntry(_ speaker: String, _ text: String, _ startMs: Int) -> LiveEntry {
        LiveEntry(
            speakerId: speaker,
            text: text,
            startMs: startMs,
            confidence: 0.95,
            translationStatus: "none",
            language: "en",
            sourceLanguage: nil
        )
    }

    // MARK: - Commands

    /// A slice of the real registry shape: title plus the shortcut hint the
    /// palette draws as key caps.
    static var commands: [RTICommand] { [
        RTICommand(id: "session.start", title: "Start Recording", subtitle: "⌘⇧R", perform: {}),
        RTICommand(id: "session.pause", title: "Pause Recording", subtitle: "⌘⇧P", perform: {}),
        RTICommand(id: "overlay.toggle", title: "Toggle Overlay", subtitle: "⌘\\", perform: {}),
        RTICommand(id: "action.assist", title: "Assist", subtitle: "⌘⏎", perform: {}),
        RTICommand(id: "note.quick", title: "Quick Note", subtitle: "⌘⌥N", perform: {}),
        RTICommand(id: "view.sessions", title: "Open Sessions", subtitle: nil, perform: {}),
        RTICommand(id: "settings.open", title: "Settings…", subtitle: "⌘,", perform: {}),
    ] }

    // MARK: - Dates

    /// Noon, `days` from 2026-09-12, in the current calendar: fixed, so a
    /// proof that prints a day prints the same day every run.
    static func fixedDay(_ days: Int) -> Date {
        let calendar = Calendar.current
        let base = calendar.date(from: DateComponents(year: 2026, month: 9, day: 12, hour: 12)) ?? Date()
        return calendar.date(byAdding: .day, value: days, to: base) ?? base
    }
}
