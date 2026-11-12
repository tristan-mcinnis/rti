import Foundation
import Observation
import RTICore

@Observable @MainActor
final class SessionMarkers {
    static let shared = SessionMarkers()
    private(set) var timeline = MarkerTimeline(events: [])
    private(set) var sessionID: String?
    private(set) var directory: URL?
    private(set) var pinned: StimulusPackage?
    var preparedProjectID: String?
    var prepared: StimulusPackage?
    var selection = Set<String>()
    var lastError: String?
    var showsControls = false
    private var failedEvent: SessionNote?
    private var group: String?

    func context(at ms: Int) -> MarkerContext {
        timeline.context(at: ms)
    }

    func start(sessionID: String, in directory: URL, group: String?, research: Bool) throws {
        self.sessionID = sessionID
        self.directory = directory
        self.group = group
        pinned = research && preparedProjectID == MeetingContextStore.shared.workstreamItem?.url.path ? prepared : nil
        selection = []
        failedEvent = nil
        lastError = nil
        timeline = try MarkerTimeline(events: SessionMarkerJournal.read(in: directory))
        if let pinned {
            let url = directory.appendingPathComponent("stimulus-package.json")
            try JSONEncoder().encode(pinned).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    var offset: Int {
        let session = SessionCoordinator.shared
        guard let zero = session.audioPipeline.captureStartWall ?? session.startedAt else { return 0 }
        return Int(max(0, Date().timeIntervalSince(zero) * 1000))
    }

    func type(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let marker = trimmed.hasPrefix("/") && trimmed.count > 1
        let qid = marker ? GuideSessionController.shared.resolveMarker(label: String(trimmed.dropFirst())) : nil
        let event = SessionNote(kind: marker ? .marker : .note, offsetMs: offset, text: text, guideQuestionID: qid,
                                sessionID: sessionID, groupID: group)
        guard save(event) else { return false }
        if marker {
            _ = GuideSessionController.shared.selectMarker(label: event.label, atMs: event.offsetMs)
        }
        return true
    }

    @discardableResult
    func mark(clear: Bool = false, correcting prior: SessionNote? = nil, at override: Int? = nil) -> Bool {
        guard let pinned, clear || !selection.isEmpty else { return false }
        let chosen = clear ? [] : pinned.items.filter { selection.contains($0.id) }
        let labels = chosen.map(\.code)
        let title = clear ? "Materials cleared" : labels.joined(separator: " + ")
        var event = SessionNote(kind: prior == nil ? .stimulus : .correction, offsetMs: offset, text: title, shownCodes: labels,
                                revealed: chosen.contains(where: \.endsBlind), packageRevision: pinned.revision,
                                sessionID: sessionID, groupID: group, replaces: prior?.id)
        event.shownItemIDs = chosen.map(\.id)
        if let prior {
            var replacement = SessionNote.Replacement(text: title, shownCodes: labels, offsetMs: override ?? prior.offsetMs,
                                                      guideQuestionID: prior.guideQuestionID)
            replacement.shownItemIDs = event.shownItemIDs
            event.replacement = replacement
        }
        return save(event)
    }

    private func save(_ requested: SessionNote) -> Bool {
        let session = SessionCoordinator.shared
        guard session.isRunning, let directory, sessionID == session.currentSessionId else {
            lastError = "Start a recording to mark its transcript."
            return false
        }
        var event = requested
        if let failedEvent, failedEvent.kind == event.kind, failedEvent.text == event.text,
           failedEvent.shownItemIDs == event.shownItemIDs, failedEvent.replaces == event.replaces,
           failedEvent.replacement == event.replacement
        {
            event = failedEvent
        }
        do {
            timeline = try MarkerTimeline(events: SessionMarkerJournal.append(event, in: directory))
            failedEvent = nil
            lastError = nil
            session.applyJournalNotes(timeline.entries)
            if event.kind == .correction {
                ResearchCodebookController.shared.markersDidChange()
            }
            if event.kind != .note {
                GuideSessionController.shared.markersDidChange()
            }
            return true
        } catch {
            failedEvent = event
            lastError = "Note or marker was not saved. Retry: " + error.localizedDescription
            session.lastError = lastError
            return false
        }
    }
}
