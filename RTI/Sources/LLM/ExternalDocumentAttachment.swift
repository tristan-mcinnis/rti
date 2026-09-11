import Foundation
import PDFKit
import RTICore
import UniformTypeIdentifiers

/// A document selected for one Assist turn. Its extracted text lives only in
/// memory and is discarded after the request; RTI never copies the source file
/// into the vault or session archive.
struct ExternalDocumentAttachment: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let text: String
    /// Where it was read from, for the chip's tooltip and the turn record.
    let path: String?
    /// PDF or text; drives the chip's glyph and its detail.
    let kind: ChatAttachmentRef.Kind
    /// Size of the file on disk.
    let byteCount: Int?
    /// Pages of a PDF.
    let pageCount: Int?
    /// True when the text was cut to `ExternalDocumentLoader.maxCharacters`.
    /// The chip says "cut"; before it was silent.
    let wasCut: Bool

    init(
        name: String,
        text: String,
        path: String? = nil,
        kind: ChatAttachmentRef.Kind = .text,
        byteCount: Int? = nil,
        pageCount: Int? = nil,
        wasCut: Bool = false
    ) {
        self.name = name
        self.text = text
        self.path = path
        self.kind = kind
        self.byteCount = byteCount
        self.pageCount = pageCount
        self.wasCut = wasCut
    }

    /// The reference a chip and a sent question carry: never the text.
    var ref: ChatAttachmentRef {
        ChatAttachmentRef(kind: kind, name: name, path: path, byteCount: byteCount, pageCount: pageCount, wasCut: wasCut)
    }
}

enum ExternalDocumentLoader {
    static let maxBytes = 512 * 1024
    static let maxCharacters = 24_000

    enum LoadError: LocalizedError, Equatable {
        case unsupported(String)
        case tooLarge
        case unreadable
        case noText

        var errorDescription: String? {
            switch self {
            case let .unsupported(name): "\(name) isn't a supported attachment. Attach a PDF, Markdown, or plain-text file."
            case .tooLarge: "That file is too large to attach. Choose a file under 512 KB."
            case .unreadable: "RTI couldn't read that file."
            case .noText: "No readable text was found in that file."
            }
        }

        /// The reason as a failed chip's detail: short, so the chip stays
        /// one line.
        var chipReason: String {
            switch self {
            case .unsupported: "Not a PDF or text file"
            case .tooLarge: "Over 512 KB; not read"
            case .unreadable: "Could not be read"
            case .noText: "No text found"
            }
        }
    }

    static func load(url: URL) throws -> ExternalDocumentAttachment {
        guard url.isFileURL else { throw LoadError.unreadable }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        let byteCount = values.fileSize
        guard (byteCount ?? 0) <= maxBytes else { throw LoadError.tooLarge }

        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        let text: String
        let kind: ChatAttachmentRef.Kind
        var pageCount: Int?
        if type.conforms(to: .pdf) {
            guard let document = PDFDocument(url: url) else { throw LoadError.unreadable }
            text = document.string ?? ""
            kind = .pdf
            pageCount = document.pageCount
        } else if type.conforms(to: .text) || ["md", "markdown", "csv", "json", "yaml", "yml"].contains(url.pathExtension.lowercased()) {
            let data = try Data(contentsOf: url)
            text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .unicode)
                ?? ""
            kind = .text
        } else {
            throw LoadError.unsupported(url.lastPathComponent)
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LoadError.noText }
        return ExternalDocumentAttachment(
            name: url.lastPathComponent,
            text: String(trimmed.prefix(maxCharacters)),
            path: url.path,
            kind: kind,
            byteCount: byteCount,
            pageCount: pageCount,
            wasCut: trimmed.count > maxCharacters
        )
    }
}
