import Foundation
import RTICore

/// The short generated title for a session that has notes but no title from
/// the summary, the vault, or the calendar (`SessionTitleResolver` rule 5).
///
/// One cheap call (thinking off) over the `notes.md` slice headings, a few
/// hundred characters. The Sessions window runs it lazily, one session at a
/// time, so the call stays out of the recording and finishing path. It
/// never runs from the session writer.
enum SessionTitleGenerator {
    /// Time allowed for the call; a title is not worth waiting longer.
    static let timeout: Double = 30

    /// A title from the notes' headings, or nil when there are no headings
    /// or the call fails.
    @MainActor
    static func generate(notesMarkdown: String) async -> String? {
        let headings = SessionTitleResolver.noteHeadings(fromNotesMarkdown: notesMarkdown)
        guard !headings.isEmpty else { return nil }
        let prompt = SessionTitleResolver.titlePrompt(headings: headings)
        guard let reply = await LLMRequest().collectAsync(
            messages: [LLMMessage(role: "user", content: prompt)],
            smart: false,
            timeoutOverride: timeout
        ) else {
            RTILog.log("session title: call failed", category: .summary)
            return nil
        }
        return SessionTitleResolver.cleanGeneratedTitle(reply)
    }

    /// Save a generated title as `title.txt`, plus `title-generated.txt`
    /// holding the same text so the resolver ranks it below the vault note
    /// and the calendar. Does nothing when a title already exists or the
    /// user set one. Owner-only, like every archive file.
    static func persist(_ title: String, in sessionDirectory: URL) {
        let fm = FileManager.default
        let titleURL = sessionDirectory.appendingPathComponent(SessionTitleResolver.titleFileName)
        let manualURL = sessionDirectory.appendingPathComponent(SessionTitleResolver.manualMarkerFileName)
        guard !fm.fileExists(atPath: titleURL.path), !fm.fileExists(atPath: manualURL.path) else { return }
        let markerURL = sessionDirectory.appendingPathComponent(SessionTitleResolver.generatedMarkerFileName)
        for url in [markerURL, titleURL] {
            do {
                try title.write(to: url, atomically: true, encoding: .utf8)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch {
                RTILog.log("session title: couldn't write \(url.lastPathComponent): \(error.localizedDescription)", category: .summary)
                return
            }
        }
    }
}
