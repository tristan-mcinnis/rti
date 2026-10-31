import AppKit
import Foundation
import HouseChatCore
import HouseChatDocuments
import Observation
import RTICore

/// The exact bytes and facts behind one source a turn was handed.
///
/// Built once at send time from the typed attachment or the captured
/// screenshot. Persistence reads this and never re-reads a path, so one
/// attachment's bytes can never be substituted for another's.
struct ChatSourcePayload: Sendable, Equatable {
    var name: String
    /// The chip kind this source is shown as.
    var displayKind: ChatAttachmentRef.Kind
    /// The archive kind, from the extractor's own record.
    var archiveKind: AttachmentKind
    var path: String?
    var byteCount: Int?
    var pageCount: Int?
    var wasCut: Bool
    var originalBytes: Data?
    var originalExtension: String?
    var normalizedImage: Data?
    var normalizedImageExtension: String?
    /// The mime type of `normalizedImage`, so a wire `LLMImage` carries the
    /// exact bytes with the right label.
    var normalizedImageMimeType: String?
    var extractedText: String?
    var document: ExtractedDocument?

    init(from attachment: ExternalDocumentAttachment) {
        self.name = attachment.name
        self.displayKind = attachment.kind
        self.archiveKind = attachment.document.kind
        self.path = attachment.path
        self.byteCount = attachment.byteCount
        self.pageCount = attachment.pageCount
        self.wasCut = attachment.wasCut
        self.originalBytes = attachment.originalBytes.isEmpty ? nil : attachment.originalBytes
        self.originalExtension = attachment.path.map { URL(fileURLWithPath: $0).pathExtension }
            .flatMap { $0.isEmpty ? nil : $0 }
        self.normalizedImage = attachment.normalizedImage?.data
        self.normalizedImageExtension = Self.fileExtension(forMime: attachment.normalizedImage?.mimeType)
        self.normalizedImageMimeType = attachment.normalizedImage?.mimeType
        self.extractedText = attachment.text
        self.document = attachment.document
    }

    init(screenJPEG: Data?, ocrText: String?) {
        self.name = "Screenshot"
        self.displayKind = .screen
        self.archiveKind = .screenshot
        self.path = nil
        self.byteCount = screenJPEG?.count
        self.pageCount = nil
        self.wasCut = false
        self.originalBytes = screenJPEG
        self.originalExtension = screenJPEG == nil ? nil : "jpg"
        self.normalizedImage = screenJPEG
        self.normalizedImageExtension = screenJPEG == nil ? nil : "jpg"
        self.normalizedImageMimeType = screenJPEG == nil ? nil : "image/jpeg"
        self.extractedText = ocrText
        self.document = nil
    }

    /// A source read back from the store for a follow-up. Its bytes come from
    /// the store, never from a path, so a moved or deleted original does not
    /// change what the follow-up is answered from.
    init(retained name: String, kind: AttachmentKind, path: String?, originalBytes: Data?, normalizedImage: Data?, normalizedImageMimeType: String?, extractedText: String?, document: ExtractedDocument?) {
        self.name = name
        self.displayKind = Self.displayKind(for: kind)
        self.archiveKind = kind
        self.path = path
        self.byteCount = originalBytes?.count
        self.pageCount = document?.sectionUnit == .page ? document?.unitCount : nil
        self.wasCut = document?.truncation != nil
        self.originalBytes = originalBytes
        self.originalExtension = Self.fileExtension(forKind: kind, name: name)
        self.normalizedImage = normalizedImage
        self.normalizedImageExtension = Self.fileExtension(forMime: normalizedImageMimeType)
        self.normalizedImageMimeType = normalizedImageMimeType
        self.extractedText = extractedText ?? document?.text
        self.document = document
    }

    static func displayKind(for kind: AttachmentKind) -> ChatAttachmentRef.Kind {
        switch kind {
        case .pdf: .pdf
        case .image: .image
        case .screenshot: .screen
        case .text, .markdown, .code, .html: .text
        default: .vaultFile
        }
    }

    private static func fileExtension(forKind kind: AttachmentKind, name: String) -> String? {
        let ext = URL(fileURLWithPath: name).pathExtension
        if !ext.isEmpty { return ext }
        return kind == .pdf ? "pdf" : nil
    }

    /// A dated legacy log handed over from the Chats library. The recorded
    /// text is the source; the log path stays a metadata-only reference.
    init(dated name: String, sourcePath: String?, text: String, document: ExtractedDocument?) {
        self.name = name
        self.displayKind = .text
        self.archiveKind = .markdown
        self.path = sourcePath
        self.byteCount = text.utf8.count
        self.pageCount = nil
        self.wasCut = false
        self.originalBytes = text.data(using: .utf8)
        self.originalExtension = "txt"
        self.normalizedImage = nil
        self.normalizedImageExtension = nil
        self.normalizedImageMimeType = nil
        self.extractedText = text
        self.document = document
    }

    /// A mention of a vault file: text plus the file's own bytes, when they
    /// were read at hand-over time. Never re-read later.
    init(name: String, path: String, text: String, bytes: Data?, document: ExtractedDocument?, wasCut: Bool = false) {
        self.name = name
        self.displayKind = .vaultFile
        self.archiveKind = .markdown
        self.path = path
        self.byteCount = bytes?.count
        self.pageCount = nil
        self.wasCut = wasCut
        self.originalBytes = bytes
        self.originalExtension = URL(fileURLWithPath: path).pathExtension.isEmpty
            ? nil : URL(fileURLWithPath: path).pathExtension
        self.normalizedImage = nil
        self.normalizedImageExtension = nil
        self.normalizedImageMimeType = nil
        self.extractedText = text
        self.document = document
    }

    /// The record the store commits for this source.
    var submitted: ChatThreadStore.SubmittedAttachment {
        ChatThreadStore.SubmittedAttachment(
            kind: archiveKind,
            name: name,
            path: path,
            byteCount: byteCount,
            pageCount: pageCount,
            originalBytes: originalBytes,
            originalExtension: originalExtension,
            normalizedImage: normalizedImage,
            normalizedImageExtension: normalizedImageExtension,
            extractedText: extractedText,
            extractedDocument: document,
            wasCut: wasCut
        )
    }

    private static func fileExtension(forMime mime: String?) -> String? {
        switch mime {
        case "image/png": "png"
        case "image/jpeg", "image/jpg": "jpg"
        case "image/heic": "heic"
        default: mime?.split(separator: "/").last.map(String.init)
        }
    }
}
