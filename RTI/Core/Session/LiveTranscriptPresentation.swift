import Foundation

public enum LiveTranscriptPresentation {
    public enum SpeakerLabelStyle: Equatable {
        case neutral
        case displayNames([String: String])
    }

    public struct Row: Identifiable, Equatable {
        public let id: UUID
        public let speakerId: String
        public let speakerLabel: String
        public let startMs: Int
        public var original: String
        public var translation: String
        public var translationLanguage: String?

        public var isNote: Bool { speakerId == "note" }
        public var hasOriginal: Bool { !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        public var hasTranslation: Bool { !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    public static func rows(
        from entries: [LiveEntry],
        showTranslations: Bool,
        speakerLabelStyle: SpeakerLabelStyle = .neutral
    ) -> [Row] {
        var result: [Row] = []
        var speakerNumber: [String: Int] = [:]
        var nextNumber = 1

        func label(for speakerId: String) -> String {
            if speakerId == "note" { return "Note" }
            switch speakerLabelStyle {
            case .neutral:
                if let n = speakerNumber[speakerId] { return "Speaker \(n)" }
                let n = nextNumber
                speakerNumber[speakerId] = n
                nextNumber += 1
                return "Speaker \(n)"
            case let .displayNames(names):
                if let name = names[speakerId] { return name }
                return speakerId
            }
        }

        for entry in entries {
            let isTranslation = entry.translationStatus == "translation"
            let canMerge = !entry.speakerId.isEmpty
                && entry.speakerId != "note"
                && result.last?.speakerId == entry.speakerId

            if canMerge, let lastIndex = result.indices.last {
                if isTranslation {
                    append(entry.text, to: &result[lastIndex].translation)
                    result[lastIndex].translationLanguage = entry.language ?? result[lastIndex].translationLanguage
                } else {
                    append(entry.text, to: &result[lastIndex].original)
                }
            } else {
                result.append(Row(
                    id: entry.id,
                    speakerId: entry.speakerId,
                    speakerLabel: label(for: entry.speakerId),
                    startMs: entry.startMs,
                    original: isTranslation ? "" : entry.text,
                    translation: isTranslation ? entry.text : "",
                    translationLanguage: isTranslation ? entry.language : nil
                ))
            }
        }

        return result.filter { row in
            row.hasOriginal || (showTranslations && row.hasTranslation)
        }
    }

    public static func copyText(rows: [Row], showTranslations: Bool) -> String {
        rows.map { copyText(row: $0, showTranslations: showTranslations) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    public static func copyText(row: Row, showTranslations: Bool) -> String {
        let original = row.original.trimmingCharacters(in: .whitespacesAndNewlines)
        let translation = row.translation.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts: [String] = []
        if !original.isEmpty {
            parts.append("[\(formatOffset(row.startMs))] \(row.speakerLabel): \(original)")
        }
        if showTranslations, !translation.isEmpty {
            let label = row.translationLanguage.map { "Translation \($0.uppercased())" } ?? "Translation"
            parts.append("[\(formatOffset(row.startMs))] \(label): \(translation)")
        }
        return parts.joined(separator: "\n")
    }

    private static func append(_ text: String, to target: inout String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        target += (target.isEmpty ? "" : " ") + trimmed
    }

    private static func formatOffset(_ ms: Int) -> String {
        let totalSeconds = max(0, ms / 1000)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
