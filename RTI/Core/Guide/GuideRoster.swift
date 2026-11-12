import Foundation

public struct GuideSeat: Codable, Equatable, Hashable, Sendable {
    public let seat: Int
    public let label: String
    public let segment: String

    public init(seat: Int, label: String, segment: String) {
        self.seat = seat
        self.label = label
        self.segment = segment
    }

    public var code: String {
        "\(seat)\(segment)"
    }
}

public enum GuideRoster {
    public enum ParseError: LocalizedError {
        case unsupportedFormat, invalidCSV, invalidSeat, duplicateSeat, empty

        public var errorDescription: String? {
            switch self {
            case .unsupportedFormat: "Choose a JSON or CSV roster."
            case .invalidCSV: "Use CSV columns seat, label and segment."
            case .invalidSeat: "Each respondent needs a positive seat number, a label and a U, C or L segment."
            case .duplicateSeat: "Each seat number must appear once in the roster."
            case .empty: "The roster has no respondents."
            }
        }
    }

    public static func parse(_ data: Data, fileExtension: String) throws -> [GuideSeat] {
        let seats: [GuideSeat]
        switch fileExtension.lowercased() {
        case "json":
            seats = try JSONDecoder().decode([GuideSeat].self, from: data)
        case "csv":
            seats = try csvSeats(data)
        default:
            throw ParseError.unsupportedFormat
        }
        guard !seats.isEmpty else { throw ParseError.empty }
        var seen = Set<Int>()
        return try seats.map { item in
            let label = item.label.trimmingCharacters(in: .whitespacesAndNewlines)
            let segment = item.segment.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard item.seat > 0, !label.isEmpty, ["U", "C", "L"].contains(segment) else {
                throw ParseError.invalidSeat
            }
            guard seen.insert(item.seat).inserted else { throw ParseError.duplicateSeat }
            return GuideSeat(seat: item.seat, label: label, segment: segment)
        }
    }

    private static func csvSeats(_ data: Data) throws -> [GuideSeat] {
        guard var text = String(data: data, encoding: .utf8) else { throw ParseError.invalidCSV }
        if text.first == "\u{feff}" {
            text.removeFirst()
        }
        let rows = try csvRows(text)
        guard let headers = rows.first?.map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }),
              let number = headers.firstIndex(of: "seat"), let label = headers.firstIndex(of: "label"),
              let segment = headers.firstIndex(of: "segment")
        else { throw ParseError.invalidCSV }
        return try rows.dropFirst().map { row in
            guard row.count == headers.count, let seat = Int(row[number].trimmingCharacters(in: .whitespaces))
            else { throw ParseError.invalidCSV }
            return GuideSeat(seat: seat, label: row[label], segment: row[segment])
        }
    }

    private static func csvRows(_ text: String) throws -> [[String]] {
        enum FieldState { case plain, quoted, afterQuote }
        var state = FieldState.plain
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        func finishRow() {
            row.append(field)
            if row.contains(where: { !$0.isEmpty }) {
                rows.append(row)
            }
            row = []
            field = ""
        }
        for character in text {
            if state == .quoted {
                if character == "\"" {
                    state = .afterQuote
                } else {
                    field.append(character)
                }
            } else if character == "," {
                row.append(field)
                field = ""
                state = .plain
            } else if character.isNewline {
                finishRow()
                state = .plain
            } else if character == "\"" {
                if state == .afterQuote {
                    field.append(character)
                } else if !field.isEmpty {
                    throw ParseError.invalidCSV
                }
                state = .quoted
            } else {
                guard state == .plain else { throw ParseError.invalidCSV }
                field.append(character)
            }
        }
        guard state != .quoted else { throw ParseError.invalidCSV }
        finishRow()
        return rows
    }
}
