import Foundation

// Structured records a chat turn carries, so the thread can draw what a turn
// used (attachments), what it did (tool lines), and what it cited (sources)
// from data rather than by sniffing streamed text. In memory only, like the
// chat itself: nothing here is persisted.

/// One thing sent with a question: a vault file picked with `@`, a document
/// attached from disk, or one read of the screen. A reference, never the text.
/// Shaped after Quick Launch's `ChatAttachmentRef`, cut to RTI's kinds.
public struct ChatAttachmentRef: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable, CaseIterable {
        /// A vault file picked with an `@` mention.
        case vaultFile
        /// A PDF attached from disk.
        case pdf
        /// A plain text or Markdown file attached from disk.
        case text
        /// One screen or window read: OCR text, and the image itself when the
        /// model takes image input. Nothing is retained in the record.
        case screen

        /// The chip's kind glyph (chat-surfaces.md section 4).
        public var symbolName: String {
            switch self {
            case .vaultFile: "doc.text"
            case .pdf: "doc.richtext"
            case .text: "text.alignleft"
            case .screen: "camera.viewfinder"
            }
        }
    }

    public let kind: Kind
    /// The file name, or "Screen" for a screen read.
    public let name: String
    /// A vault-relative path for `vaultFile`, an absolute path for a
    /// document. Nil for a screen read.
    public let path: String?
    /// Size of the source file in bytes, when known.
    public let byteCount: Int?
    /// Pages of a PDF, when known.
    public let pageCount: Int?
    /// True when the text was cut to fit the per-document cap.
    public let wasCut: Bool

    public init(
        kind: Kind,
        name: String,
        path: String? = nil,
        byteCount: Int? = nil,
        pageCount: Int? = nil,
        wasCut: Bool = false
    ) {
        self.kind = kind
        self.name = name
        self.path = kind == .screen ? nil : path
        self.byteCount = byteCount
        self.pageCount = pageCount
        self.wasCut = wasCut
    }
}

/// One tool or status line above an answer: what the assistant did to get
/// there ("Searched vault · 6 results", "Read the screen"). The glyph comes
/// from the kind, so a settled answer draws the same lines it drew live.
public struct ChatToolLine: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable, CaseIterable {
        /// `search_vault`: the Neon hybrid index.
        case searchVault
        /// `grep_vault`: literal text search in the vault.
        case grepVault
        /// `read_document`: one file read in full.
        case readDocument
        /// `list_files`: a folder listed.
        case listFiles
        /// `recent_meetings`: the meeting list checked.
        case recentMeetings
        /// `capture_screen` or a one-off screen read.
        case readScreen
        /// `highlight_screen_text`: text marked on screen.
        case highlightScreen
        /// The live transcript attached as context.
        case transcript
        /// Anything else the assistant reports.
        case other

        /// The line's glyph (chat-surfaces.md section 2, plan section 4).
        public var symbolName: String {
            switch self {
            case .searchVault: "archivebox"
            case .grepVault: "magnifyingglass"
            case .readDocument: "doc.text"
            case .listFiles: "folder"
            case .recentMeetings: "calendar"
            case .readScreen: "camera.viewfinder"
            case .highlightScreen: "highlighter"
            case .transcript: "waveform"
            case .other: "sparkle"
            }
        }
    }

    public let kind: Kind
    /// The line as drawn: plain, short, no trailing period.
    public let text: String

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }
}

/// One source an answer cited: a row in the quiet list under the prose.
public struct ChatSource: Hashable, Sendable {
    /// The row title: the note's title, else the file name.
    public let title: String
    /// Vault-relative path (the shape `search_vault` returns), or an
    /// absolute path for a file outside the vault.
    public let path: String
    /// The day the row shows, when the source has one.
    public let date: Date?

    public init(title: String, path: String, date: Date? = nil) {
        self.title = title
        self.path = path
        self.date = date
    }
}
