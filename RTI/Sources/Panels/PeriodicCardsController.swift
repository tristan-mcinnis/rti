import Foundation
import Observation

/// Drives one periodic-cards panel: holds a timer, runs the configured
/// LLM prompt against the recent transcript window each tick, and
/// persists each generated card. One controller per panel id — keyed in
/// a dictionary on the singleton so multiple panels run independently.
@Observable @MainActor
final class PeriodicCardsController {
    static let shared = PeriodicCardsController()

    private(set) var cardsByPanel: [String: [Card]] = [:]
    private(set) var generatingPanelIds: Set<String> = []

    struct Card: Identifiable, Equatable {
        let id: String
        let createdAt: Date
        let content: String
    }

    private var timers: [String: Timer] = [:]
    private var requests: [String: LLMRequest] = [:]
    private var currentSessionId: String?

    private init() {}

    /// Bind the controller to a session: cancels any timers from a prior
    /// session, loads cached cards for each panel, and re-arms timers
    /// for every currently-configured periodic-cards panel.
    func resetForSession(_ sessionId: String?) {
        for (_, timer) in timers { timer.invalidate() }
        timers = [:]
        requests = [:]
        currentSessionId = sessionId
        cardsByPanel = [:]
        guard let sessionId else { return }
        let panels = UserPanelStore.shared.panels.filter { $0.kind == .periodicCards }
        for panel in panels {
            cardsByPanel[panel.id] = Self.loadCards(panelId: panel.id, sessionId: sessionId)
            armTimer(for: panel, sessionId: sessionId)
        }
    }

    /// Spin up a timer for a single panel — used when the user spawns a
    /// new panel mid-session and we don't want to wait for the next
    /// `resetForSession` to pick it up.
    func registerNewPanel(_ panel: UserPanel) {
        guard panel.kind == .periodicCards, let sessionId = currentSessionId else { return }
        if cardsByPanel[panel.id] == nil { cardsByPanel[panel.id] = [] }
        armTimer(for: panel, sessionId: sessionId)
    }

    func unregister(panelId: String) {
        timers[panelId]?.invalidate()
        timers[panelId] = nil
        requests[panelId]?.cancel()
        requests[panelId] = nil
        cardsByPanel[panelId] = nil
    }

    private func armTimer(for panel: UserPanel, sessionId: String) {
        guard case .periodicCards = panel.kind, let cfg = panel.config.periodicCards else { return }
        timers[panel.id]?.invalidate()
        // Clamp the interval to a sane band — a hallucinated config with
        // interval=5 would otherwise hammer the API every five seconds.
        let interval = max(60.0, min(600.0, cfg.intervalSeconds))
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.fire(panelId: panel.id) }
        }
        timer.tolerance = 5
        timers[panel.id] = timer
    }

    private func fire(panelId: String) {
        guard let panel = UserPanelStore.shared.panels.first(where: { $0.id == panelId }),
              let cfg = panel.config.periodicCards,
              let sessionId = currentSessionId,
              !generatingPanelIds.contains(panelId) else { return }

        let transcript = TranscriptContext.text(forSessionId: sessionId)
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        generatingPanelIds.insert(panelId)
        let request = requests[panelId] ?? LLMRequest()
        requests[panelId] = request

        Task { @MainActor [weak self] in
            defer { self?.generatingPanelIds.remove(panelId) }
            let messages: [LLMMessage] = [
                LLMMessage(role: "system",
                           content: "You are an analyst on a live meeting. Run the user's instruction against the transcript window. Be concise, factual, and output plain markdown only — no code fences."),
                LLMMessage(role: "user",
                           content: "Instruction: \(cfg.prompt)\n\nTranscript window:\n\(trimmed)")
            ]
            guard let result = await request.collectAsync(messages: messages, smart: false),
                  !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let card = Card(id: UUID().uuidString, createdAt: Date(), content: result)
            self?.cardsByPanel[panelId, default: []].append(card)
            UserPanelStore.shared.appendCard(panelId: panelId, sessionId: sessionId, content: result)
        }
    }

    private static func loadCards(panelId: String, sessionId: String) -> [Card] {
        UserPanelStore.cards(forPanelId: panelId, sessionId: sessionId)
            .map { Card(id: $0.id, createdAt: $0.createdAt, content: $0.content) }
    }
}
