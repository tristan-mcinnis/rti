import Foundation
import HouseChatCore
import HouseChatDocuments
import RTICore

/// A document selected for one Assist turn.
///
/// The reading is done by the shared `DocumentExtractor`, so RTI keeps no caps,
/// no prefix truncation rule and no format list of its own: what the package
/// read, cut, and noted is what this attachment is. The original bytes and the
/// inference-normalized image are kept separately, because a record needs both
/// and they are different things.
struct ExternalDocumentAttachment: Identifiable, Equatable {
    let id = UUID()
    let name: String
    /// The text a model reads. `DocumentContext` selects within it.
    let text: String
    /// Where it was read from, for the chip's tooltip and the turn record.
    let path: String?
    /// PDF or text; drives the chip's glyph and its detail.
    let kind: ChatAttachmentRef.Kind
    /// Size of the file on disk.
    let byteCount: Int?
    /// Pages of a PDF.
    let pageCount: Int?
    /// True when the read was cut short. Derived from the extractor's own
    /// `TextTruncation`, never from a character count of our own.
    let wasCut: Bool
    /// The bytes exactly as they arrived, for the durable record.
    let originalBytes: Data
    /// The scaled, metadata-free image for a picture; nil for anything else.
    let normalizedImage: DocumentImageBytes?
    /// The extractor's record: sections with location, notes, and the unit the
    /// document counts, so `DocumentContext` can chunk and label it.
    let document: ExtractedDocument
    /// The truncation line the extractor reported, when the read was cut.
    let limitSummary: String?

    init(
        name: String,
        text: String,
        path: String? = nil,
        kind: ChatAttachmentRef.Kind = .text,
        byteCount: Int? = nil,
        pageCount: Int? = nil,
        wasCut: Bool = false,
        originalBytes: Data = Data(),
        normalizedImage: DocumentImageBytes? = nil,
        document: ExtractedDocument,
        limitSummary: String? = nil
    ) {
        self.name = name
        self.text = text
        self.path = path
        self.kind = kind
        self.byteCount = byteCount
        self.pageCount = pageCount
        self.wasCut = wasCut
        self.originalBytes = originalBytes
        self.normalizedImage = normalizedImage
        self.document = document
        self.limitSummary = limitSummary
    }

    /// The reference a chip and a sent question carry: never the text.
    var ref: ChatAttachmentRef {
        ChatAttachmentRef(kind: kind, name: name, path: path, byteCount: byteCount, pageCount: pageCount, wasCut: wasCut)
    }

    /// A preview of the same fields, used by the render proofs and by tests
    /// that must not read a real file.
    static func fixture(
        name: String = "report.pdf",
        text: String = "The number is 42.",
        kind: ChatAttachmentRef.Kind = .pdf
    ) -> ExternalDocumentAttachment {
        ExternalDocumentAttachment(
            name: name,
            text: text,
            path: nil,
            kind: kind,
            byteCount: text.utf8.count,
            pageCount: kind == .pdf ? 1 : nil,
            document: ExtractedDocument.flat(
                kind: kind == .pdf ? .pdf : .text,
                kindLabel: kind == .pdf ? "PDF" : "Text",
                name: name,
                text: text
            )
        )
    }
}

/// One reader, the shared one. This type no longer decides what is readable,
/// how much text is kept, or when a read counts as cut — `DocumentExtractor`
/// does, and this maps its result onto RTI's chip.
enum ExternalDocumentLoader {
    /// The extractor's own caps, re-exported here so a caller reads the numbers
    /// from one place. RTI does not own these limits any more; the shared
    /// reader does.
    static var maxBytes: Int {
        DocumentExtractionConfiguration.standard.maximumDocumentBytes
    }

    static var maxTextBytes: Int {
        DocumentExtractionConfiguration.standard.maximumTextFileBytes
    }

    static var maxCharacters: Int {
        DocumentExtractionConfiguration.standard.maximumCharacters
    }

    enum LoadError: LocalizedError, Equatable {
        /// The file is over the cap for its kind.
        case tooLarge
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .tooLarge: "That file is too large to attach."
            case .failed(let detail): detail
            }
        }

        /// The reason as a failed chip's detail: short, so the chip stays one
        /// line.
        var chipReason: String {
            switch self {
            case .tooLarge: "Too large to attach"
            case .failed(let detail): detail
            }
        }
    }

    static func load(url: URL) async throws -> ExternalDocumentAttachment {
        guard url.isFileURL else { throw LoadError.failed("Not a file") }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let extraction: DocumentExtraction
        do {
            extraction = try await DocumentExtractor().extract(fileURL: url)
        } catch let error as DocumentExtractionError {
            if case .tooLarge = error { throw LoadError.tooLarge }
            throw LoadError.failed(Self.chipReason(for: error))
        } catch {
            throw LoadError.failed("Could not be read")
        }

        let document = extraction.document
        let text = (document.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw LoadError.failed("No text found") }

        return ExternalDocumentAttachment(
            name: extraction.source.name,
            text: text,
            path: url.path,
            kind: Self.chipKind(for: document.kind),
            byteCount: extraction.originalBytes.count,
            pageCount: document.sectionUnit == .page ? document.unitCount : nil,
            wasCut: document.truncation != nil || !extraction.isComplete,
            originalBytes: extraction.originalBytes,
            normalizedImage: extraction.normalizedImage,
            document: document,
            limitSummary: extraction.limitSummary
        )
    }

    /// A short, human reason for a refused read.
    static func chipReason(for error: DocumentExtractionError) -> String {
        switch error {
        case .passwordProtected: "Needs a password"
        case .damaged: "The file is damaged"
        case .scannedNoText: "A scan with no readable text"
        case .tooLarge: "Too large to attach"
        case .tooLargeUnpacked: "Too large to unpack"
        case .notDownloaded: "Still downloading"
        case .accessDenied: "RTI cannot read that file"
        case .missing: "That file is gone"
        case .wrongContent: "The contents do not match the name"
        case .empty: "No text found"
        case .folder: "That is a folder"
        case .notRegularFile: "Not a plain file"
        case .unsupported: "Not a supported attachment"
        case .timedOut: "Reading took too long"
        case .unreadable: "Could not be read"
        }
    }

    private static func chipKind(for kind: AttachmentKind) -> ChatAttachmentRef.Kind {
        switch kind {
        case .pdf: .pdf
        case .text, .markdown, .code, .html: .text
        case .image: .image
        case .screenshot: .screen
        default: .text
        }
    }
}
