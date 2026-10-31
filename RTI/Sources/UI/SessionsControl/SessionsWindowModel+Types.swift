import AppKit
import Observation
import RTICore
import UniformTypeIdentifiers
import HouseDesign

extension SessionsWindowModel {
    // MARK: - Types

    /// One archived session as the window shows it.
    struct Row: Identifiable, Equatable, Sendable {
        let session: SessionArchive.ArchivedSession
        var title: ResolvedSessionTitle
        let durationSeconds: Int?
        let project: String?
        let mode: String?
        let speakerNames: [String]
        let stamp: String?
        var transcriptStatus: String?
        /// Read once at load (off the main thread), so row menus stay cheap.
        var hasTranscript = false
        var hasRetainedAudio = false
        /// `transcript.md` relative to `databases/`, for Ask in RTI.
        var vaultTranscriptPath: String?
        /// Durable identity from session.json, matching saved chat SessionLink ids.
        var sessionID: String?
        var recordingError: String? = nil

        var id: String { session.url.path }
        var folderName: String { session.url.lastPathComponent }
        /// A built title (date and length, or a short test), not a name.
        var isFallbackTitle: Bool { title.source == .fallback || title.source == .shortTest }

        var railItem: SessionRailItem {
            SessionRailItem(
                id: id,
                title: title.text,
                startedAt: session.date,
                durationSeconds: durationSeconds,
                project: project,
                mode: mode,
                speakerNames: speakerNames,
                stamp: stamp
            )
        }
    }

    /// One file pill under the header.
    struct SessionFile: Identifiable, Hashable {
        var id: URL { url }
        let url: URL
        /// "notes", "transcript", "chat", "screen-context", "frames", or "log".
        let name: String

        var displayName: String {
            switch name {
            case "notes": "Notes"
            case "transcript": "Transcript"
            case "chat": "Chat"
            case "screen-context": "Screen"
            case "frames": "Screenshots"
            case "log": "Log"
            default: name.capitalized
            }
        }
    }

    /// The open file, split into the blocks the reader draws, so find can
    /// mark and scroll to the block that holds a hit.
    enum ReaderDocument: Equatable {
        case empty
        case transcript([SessionTranscriptTurn])
        case chat([ArchivedChatTurn])
        case markdown([String])
        case log(String)
        case frames(URL)

        /// The searchable text of each block, in drawing order.
        var blockTexts: [String] {
            switch self {
            case .empty, .frames: []
            case let .transcript(turns): turns.map(\.text)
            case let .chat(turns): turns.map { $0.role == .user ? $0.pillText : $0.text }
            case let .markdown(blocks): blocks
            case let .log(text): [text]
            }
        }
    }

    /// One find hit: which block, and where in its text.
    struct FindHit: Equatable {
        let block: Int
        let range: Range<String.Index>
    }

    enum ContentSearchState: Equatable { case idle, searching, done, unavailable }
    enum ActionsPlacement: Equatable { case rail, header }
    enum Focus: Equatable { case none, railSearch, find, rename }

    /// A session action: in the `⌘K` card, the row's context menu, and its
    /// VoiceOver actions. Removal is confirmed and moves only RTI's own
    /// archive folder to Trash, never its separately exported meeting notes.
    enum SessionAction: String, CaseIterable, Identifiable {
        case ask, rename, nameSpeakers, editTranscript
        case upgradeTranscript, copy, share, saveMarkdown, savePDF, revealInFinder, trash

        var id: String { rawValue }

        var title: String {
            switch self {
            case .ask: "Ask in RTI"
            case .rename: "Rename"
            case .nameSpeakers: "Name Speakers"
            case .editTranscript: "Edit Transcript"
            case .upgradeTranscript: "Upgrade Transcript"
            case .copy: "Copy as Markdown"
            case .share: "Share…"
            case .trash: "Move to Trash…"
            case .saveMarkdown: "Save as Markdown"
            case .savePDF: "Save as PDF"
            case .revealInFinder: "Reveal in Finder"
            }
        }

        var systemImage: String {
            switch self {
            case .ask: "bubble.left.and.text.bubble.right"
            case .rename: "pencil"
            case .nameSpeakers: "person.2"
            case .editTranscript: "text.bubble"
            case .upgradeTranscript: "waveform.badge.magnifyingglass"
            case .copy: "doc.on.doc"
            case .share: "square.and.arrow.up"
            case .trash: "trash"
            case .saveMarkdown: "arrow.down.doc"
            case .savePDF: "doc.richtext"
            case .revealInFinder: "folder"
            }
        }

        /// The window key that runs it from anywhere, as key caps.
        var keys: [String] {
            switch self {
            case .ask: ["⌘", "J"]
            case .rename: ["⌘", "E"]
            case .copy: ["⇧", "⌘", "C"]
            case .saveMarkdown: ["⌘", "S"]
            default: []
            }
        }
    }
}
