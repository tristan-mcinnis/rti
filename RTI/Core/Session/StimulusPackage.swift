import CryptoKit
import Foundation

/// Only neutral labels and material references survive selection. The private
/// product map, route names and moderator notes never become assistant context.
public struct StimulusPackage: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Identifiable, Sendable {
        public var id: String
        public var code: String
        public var moment: String?
        public var kind: String
        public var file: String?
        public var page: Int?
        public var endsBlind: Bool
        public var sourceAvailable: Bool
    }

    public var revision: String
    public var version: String
    public var items: [Item]
    public var confirmedGroup: String?
    public var guideQuestionBindings: [String: String]?
    public var guideSectionByMoment: [String: Int]?
    public var guideSourcePaths: [String]?

    public init(revision: String, version: String, items: [Item]) {
        self.revision = revision
        self.version = version
        self.items = items
    }

    public static func read(manifest url: URL) throws -> Self {
        struct Manifest: Decodable {
            struct Slide: Decodable {
                var id: String; var moment: String?; var code: String?; var type: String?
                var ends_blind: Bool?; var options: [String]?; var seat: String?
            }

            struct Piece: Decodable { var id: String; var moment: String? }
            struct Sheet: Decodable { var spec: String; var moment: String? }
            var guide: GuidePaths?
            var source: String?; var version: String?; var slides: [Slide]?
            var pieces: [Piece]?; var worksheets: [Sheet]?
        }

        enum GuidePaths: Decodable {
            case paths([String])
            init(from decoder: Decoder) throws {
                let value = try decoder.singleValueContainer()
                if let one = try? value.decode(String.self) {
                    self = .paths([one])
                } else {
                    self = try .paths(value.decode([String].self))
                }
            }
        }
        let data = try Data(contentsOf: url)
        let spec = try JSONDecoder().decode(Manifest.self, from: data)
        let root = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        var hashes: [String: String] = [url.lastPathComponent: SHA256.hash(data: data).hex]
        func source(_ path: String?) throws -> Bool {
            guard let path, !path.hasPrefix("/") else { return false }
            if hashes[path] != nil {
                return true
            }
            let candidate = root.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
            guard candidate.path.hasPrefix(root.path + "/"),
                  (try? candidate.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return false }
            let handle = try FileHandle(forReadingFrom: candidate)
            defer { try? handle.close() }
            var digest = SHA256()
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                digest.update(data: chunk)
            }
            hashes[path] = digest.finalize().hex
            return true
        }

        var items: [Item] = []
        for (index, slide) in (spec.slides ?? []).enumerated() where slide.seat != "moderator" {
            let isDeck = spec.source?.lowercased().hasSuffix(".pptx") == true
            let path = isDeck ? spec.source : spec.source.map { $0 + "/" + slide.id + ".html" }
            let available = try source(path)
            let id = "slide/" + String(index + 1)
            items.append(Item(id: id, code: slide.code ?? "Board \(index + 1)", moment: slide.moment,
                              kind: slide.type ?? "slide", file: available ? path : nil, page: index + 1,
                              endsBlind: slide.ends_blind == true, sourceAvailable: available))
            for (optionIndex, option) in (slide.options ?? []).enumerated() {
                items.append(Item(id: id + "/option/" + String(optionIndex + 1), code: option, moment: slide.moment,
                                  kind: "option", file: available ? path : nil, page: index + 1,
                                  endsBlind: slide.ends_blind == true, sourceAvailable: available))
            }
        }
        for (index, piece) in (spec.pieces ?? []).enumerated() {
            let available = try source(piece.id)
            items.append(Item(id: "piece/" + String(index + 1), code: "Piece \(index + 1)", moment: piece.moment, kind: "piece",
                              file: available ? piece.id : nil, page: nil, endsBlind: false, sourceAvailable: available))
        }
        for (index, sheet) in (spec.worksheets ?? []).enumerated() {
            let available = try source(sheet.spec)
            items.append(Item(id: "worksheet/" + String(index + 1), code: "Worksheet \(index + 1)", moment: sheet.moment,
                              kind: "worksheet", file: available ? sheet.spec : nil, page: nil, endsBlind: false, sourceAvailable: available))
        }
        guard !items.isEmpty, Set(items.map(\.id)).count == items.count else { throw CocoaError(.fileReadCorruptFile) }
        let pairs = hashes.keys.sorted().map { [$0, hashes[$0]!] }
        let identity = try JSONSerialization.data(withJSONObject: pairs, options: .withoutEscapingSlashes)
        var result = Self(revision: SHA256.hash(data: identity).hex, version: spec.version ?? "unversioned", items: items)
        if case let .paths(paths) = spec.guide {
            result.guideSourcePaths = paths.map { root.appendingPathComponent($0).standardizedFileURL.path }
        }
        return result
    }

    public mutating func addManual(label: String, file: URL? = nil, page: Int? = nil) {
        let id = UUID().uuidString
        items.append(Item(id: "manual/" + id, code: label, moment: nil, kind: "manual", file: file?.path,
                          page: page, endsBlind: false, sourceAvailable: file.map { FileManager.default.fileExists(atPath: $0.path) } ?? false))
        revision = SHA256.hash(data: Data((revision + "|" + id).utf8)).hex
    }
}

private extension SHA256.Digest {
    var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
