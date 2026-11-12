import Foundation

/// The ordered, bilingual product of the synthesis workbook's guide parser.
public struct GuideDocument: Codable, Equatable, Sendable {
    public struct Probe: Codable, Equatable, Sendable {
        public let en: String
        public let zh: String
    }

    public struct Question: Codable, Equatable, Sendable {
        public let qid: String
        public let en: String
        public let zh: String
        public let probes: [Probe]
        public let part: String?
        public let loop: String?
        public let topic: String?
        private let mustAskFlag: Bool?
        public var mustAsk: Bool {
            mustAskFlag ?? false
        }

        private enum CodingKeys: String, CodingKey {
            case qid, en, zh, probes, part, loop, topic
            case mustAskFlag = "must_ask"
        }
    }

    public struct Section: Codable, Equatable, Sendable {
        public let id: String
        public let title: String
        public let minutes: Int?
        public let questions: [Question]
    }

    public let title: String
    public let sections: [Section]
    public let hypotheses: [String]?

    public var questions: [Question] {
        sections.flatMap(\.questions)
    }

    /// Prefer a supplied loop/part heading. Workbook exports also preserve
    /// topic names in square brackets at the beginning of a question.
    public func header(for question: Question, in section: Section) -> String {
        let bracketTopic: String? = {
            let wording = question.en.isEmpty ? question.zh : question.en
            guard wording.first == "[", let end = wording.firstIndex(of: "]") else { return nil }
            return String(wording[wording.index(after: wording.startIndex)..<end])
        }()
        let context = [question.loop, question.part].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        let topic = [question.topic, bracketTopic].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        return [context ?? section.title, topic].compactMap { $0 }.joined(separator: " · ")
    }

    public func resolveMarker(_ label: String, answered: Set<String> = []) -> String? {
        let raw = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if let exact = questions.first(where: { $0.qid.caseInsensitiveCompare(raw) == .orderedSame }) { return exact.qid }
        let matching = questions.filter { [$0.en, $0.zh].contains { !$0.isEmpty && $0.caseInsensitiveCompare(raw) == .orderedSame } }
        if matching.count == 1 { return matching[0].qid }
        let section = sections.first { $0.id.caseInsensitiveCompare(raw) == .orderedSame || $0.title.caseInsensitiveCompare(raw) == .orderedSame }
        return section?.questions.first(where: { !answered.contains($0.qid) })?.qid ?? section?.questions.first?.qid
    }

    public static func parse(_ data: Data) throws -> Self {
        let document = try JSONDecoder().decode(Self.self, from: data)
        var ids: Set<String> = []
        var sectionIDs: Set<String> = []
        guard !document.questions.isEmpty,
              document.sections.allSatisfy({ section in
                  sectionIDs.insert(section.id).inserted &&
                      section.id.wholeMatch(of: /S[1-9][0-9]*/) != nil &&
                      section.questions.allSatisfy { question in
                          question.qid.hasPrefix(section.id + "Q") &&
                              question.qid.wholeMatch(of: /S[1-9][0-9]*Q[0-9]+/) != nil &&
                              ids.insert(question.qid).inserted &&
                              !(question.en + question.zh).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      }
              })
        else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Guide needs ordered sections with distinct question IDs and wording."))
        }
        return document
    }
}

public struct GuideTurn: Equatable, Sendable {
    public let id: String
    public let speaker: String
    public let startMs: Int
    public let text: String

    public init(id: String, speaker: String, startMs: Int, text: String) {
        self.id = id
        self.speaker = speaker
        self.startMs = startMs
        self.text = text
    }
}

/// Session-local question navigation. Overlapping transcript windows can repeat
/// an ID any number of times, but never become a second piece of evidence.
public struct GuideCursor: Sendable {
    private let ids: [String]
    public private(set) var currentQID: String
    public private(set) var revision: Int = 0
    private var afterMs: Int = -1
    private var candidate: String?
    private var evidenceTimes: [String: Int] = [:]
    public private(set) var acceptedFromMs: Int?

    public init(guide: GuideDocument) {
        ids = guide.questions.map(\.qid)
        currentQID = ids.first ?? ""
    }

    public mutating func select(_ qid: String, atMs: Int) {
        guard ids.contains(qid) else { return }
        currentQID = qid
        resetEvidence(atMs: atMs)
    }

    public mutating func resetEvidence(atMs: Int) {
        revision += 1
        afterMs = atMs
        acceptedFromMs = nil
        candidate = nil
        evidenceTimes.removeAll()
    }

    @discardableResult
    public mutating func suggest(_ qid: String, evidence: [GuideTurn], revision expected: Int) -> Bool {
        guard expected == revision else { return false }
        guard let current = ids.firstIndex(of: currentQID), let next = ids.firstIndex(of: qid), next > current else {
            candidate = nil
            evidenceTimes.removeAll()
            return false
        }
        if candidate != qid {
            candidate = qid
            evidenceTimes.removeAll()
        }
        let fresh = evidence.filter { $0.startMs > afterMs && !$0.id.isEmpty }
        for turn in fresh {
            evidenceTimes[turn.id] = turn.startMs
        }
        guard let latest = evidenceTimes.values.max() else { return false }
        evidenceTimes = evidenceTimes.filter { $0.value >= latest - 90000 }
        guard evidenceTimes.count >= 2, let earliest = evidenceTimes.values.min() else { return false }
        select(qid, atMs: latest)
        acceptedFromMs = earliest
        return true
    }
}
