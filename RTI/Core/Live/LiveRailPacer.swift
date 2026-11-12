import Foundation

/// One suggestion on the live rail, with its place in the rail's life cycle:
/// `new -> shown -> pinned | dismissed | expired`, and `pinned -> dismissed`.
/// In memory only: reset at session start, never archived.
public struct LiveRailItem: Identifiable, Equatable, Sendable {
    public enum Lane: Equatable, Sendable {
        /// Say, ask and recall cards: act on these now.
        case now
        /// Flags: open threads to come back to.
        case threads
    }

    public enum State: Equatable, Sendable {
        /// Waiting for the pacer.
        case new
        case shown
        case pinned
        case dismissed
        /// Faded to "Earlier (n)".
        case expired
    }

    public let id: UUID
    public let text: String
    public let lane: Lane
    public internal(set) var state: State
    public let arrivedAt: Date
    public internal(set) var shownAt: Date?

    public init(id: UUID, text: String, lane: Lane, arrivedAt: Date) {
        self.id = id
        self.text = text
        self.lane = lane
        self.arrivedAt = arrivedAt
        state = .new
    }
}

/// The rule that keeps the rail quiet. Pure: every input is an argument,
/// and all of its limits live here.
public struct LiveRailPacer: Equatable, Sendable {
    /// At most one new item per this many seconds.
    public var spacing: TimeInterval = 60
    /// Hold after the user's own mic speech, on client calls only. On a
    /// research call the user mostly listens, so there is nothing to wait for.
    public var selfSpeechHold: TimeInterval = 4
    public var nowCap = 3
    public var threadsCap = 2
    /// An unpinned item fades to "Earlier" this long after it is shown. A
    /// candidate that waits this long is stale and is never shown.
    public var fadeAfter: TimeInterval = 240
    /// A waiting candidate older than this is dropped once a newer one waits:
    /// the rail is about what was just said.
    public var staleAfter: TimeInterval = 90

    public static let standard = LiveRailPacer()

    public init() {}

    public struct Admission: Equatable, Sendable {
        /// The one candidate to show now, or nil.
        public var admitted: UUID?
        /// Candidates that repeat a dismissed item. They never come back.
        public var duplicatesOfDismissed: [UUID] = []
        /// Candidates passed over for a newer one. They fade unseen.
        public var stale: [UUID] = []
        /// When to ask again if candidates are still waiting.
        public var retryAt: Date?
    }

    public func cap(for lane: LiveRailItem.Lane) -> Int {
        lane == .now ? nowCap : threadsCap
    }

    /// Pick at most one candidate to show. `candidates` are in arrival order.
    /// The newest pass goes first, and within one pass its first card, so
    /// the rail answers what was just said. A candidate older than
    /// `staleAfter` is dropped once a newer one waits. A lane in `fullLanes`
    /// (every slot pinned) admits nothing. An `explicit` request (the user
    /// asked for suggestions) skips the spacing and the self-speech hold, so
    /// its first card shows at once; caps, dismissals and staleness still hold.
    public func admit(
        candidates: [LiveRailItem],
        dismissed: Set<String>,
        now: Date,
        lastAdmitAt: Date?,
        selfSpokeAt: Date?,
        callType: CallType,
        fullLanes: Set<LiveRailItem.Lane> = [],
        explicit: Bool = false
    ) -> Admission {
        var result = Admission()
        var waiting: [LiveRailItem] = []
        for item in candidates {
            if dismissed.contains(Self.normalized(item.text)) {
                result.duplicatesOfDismissed.append(item.id)
            } else {
                waiting.append(item)
            }
        }
        if let newestArrival = waiting.map(\.arrivedAt).max() {
            result.stale = waiting.filter {
                $0.arrivedAt < newestArrival && now.timeIntervalSince($0.arrivedAt) > staleAfter
            }.map(\.id)
        }
        let eligible = waiting.filter { !result.stale.contains($0.id) && !fullLanes.contains($0.lane) }
        guard let newestArrival = eligible.map(\.arrivedAt).max(),
              let pick = eligible.first(where: { $0.arrivedAt == newestArrival })
        else { return result }

        var openAt = now
        if explicit {
            result.admitted = pick.id
            return result
        }
        if let lastAdmitAt {
            openAt = max(openAt, lastAdmitAt.addingTimeInterval(spacing))
        }
        if callType == .client, let selfSpokeAt {
            openAt = max(openAt, selfSpokeAt.addingTimeInterval(selfSpeechHold))
        }
        if openAt > now {
            result.retryAt = openAt
        } else {
            result.admitted = pick.id
        }
        return result
    }

    /// The text used to match a dismissed item: case, outer and repeated
    /// whitespace, and closing punctuation do not count.
    public static func normalized(_ text: String) -> String {
        let words = text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return words.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
    }
}

/// The rail's items for one call. The live controller holds one of these.
public struct LiveRailBoard: Equatable, Sendable {
    public private(set) var items: [LiveRailItem] = []
    public private(set) var lastAdmitAt: Date?
    public private(set) var selfSpokeAt: Date?
    /// The last item admitted at the user's request, which skipped the spacing.
    public private(set) var requestedID: UUID?
    public var pacer: LiveRailPacer

    public init(pacer: LiveRailPacer = .standard) {
        self.pacer = pacer
    }

    public var nowItems: [LiveRailItem] {
        visible(.now)
    }

    public var threadItems: [LiveRailItem] {
        visible(.threads)
    }

    /// Items that faded, newest first.
    public var earlier: [LiveRailItem] {
        items.filter { $0.state == .expired }.reversed()
    }

    public var waitingCount: Int {
        items.filter { $0.state == .new }.count
    }

    /// Items held back by the pacer in one lane.
    public func waitingCount(in lane: LiveRailItem.Lane) -> Int {
        items.filter { $0.lane == lane && $0.state == .new }.count
    }

    /// Items the user saw (shown, pinned, dismissed, or shown and then
    /// faded), in arrival order. Only these count as already surfaced: a
    /// card the pacer never showed may come back from a later pass.
    public var surfaced: [LiveRailItem] {
        items.filter { $0.shownAt != nil || $0.state == .dismissed }
    }

    /// True when a candidate with this text adds nothing: the same text was
    /// surfaced, or still waits for the pacer. A repeat of an item that
    /// faded unseen is new again.
    public func repeatsKnownItem(_ text: String) -> Bool {
        let key = LiveRailPacer.normalized(text)
        return items.contains { item in
            (item.shownAt != nil || item.state == .new || item.state == .dismissed)
                && LiveRailPacer.normalized(item.text) == key
        }
    }

    public func state(of id: UUID) -> LiveRailItem.State? {
        items.first { $0.id == id }?.state
    }

    /// Queue new candidates. A repeat of a surfaced or waiting item is
    /// skipped (`repeatsKnownItem`), and so is a repeat within one offer.
    public mutating func offer(_ candidates: [LiveRailItem]) {
        var offered = Set<String>()
        for candidate in candidates {
            let key = LiveRailPacer.normalized(candidate.text)
            guard !key.isEmpty, !repeatsKnownItem(candidate.text), offered.insert(key).inserted else { continue }
            var item = candidate
            item.state = .new
            item.shownAt = nil
            items.append(item)
        }
    }

    public mutating func noteSelfSpeech(at time: Date) {
        selfSpokeAt = time
    }

    public mutating func pin(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].state == .shown else { return }
        items[index].state = .pinned
    }

    public mutating func dismiss(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        switch items[index].state {
        case .new, .shown, .pinned, .expired: items[index].state = .dismissed
        case .dismissed: break
        }
    }

    public mutating func reset() {
        self = LiveRailBoard(pacer: pacer)
    }

    /// Fade shown items past `fadeAfter`, and waiting items that waited
    /// that long unseen. `advance` does this first; a new pass does it
    /// before it checks for repeats, so a card that faded unseen is new again.
    public mutating func fade(now: Date) {
        for index in items.indices {
            switch items[index].state {
            case .shown:
                if let shownAt = items[index].shownAt, now >= shownAt.addingTimeInterval(pacer.fadeAfter) {
                    items[index].state = .expired
                }
            case .new:
                if now >= items[index].arrivedAt.addingTimeInterval(pacer.fadeAfter) {
                    items[index].state = .expired
                }
            case .pinned, .dismissed, .expired:
                break
            }
        }
    }

    /// Fade old items, admit at most one candidate, apply the lane caps.
    /// Returns when to call again, or nil when nothing is pending. With
    /// `explicit`, the one admitted item skips the spacing (see `admit`).
    @discardableResult
    public mutating func advance(now: Date, callType: CallType, explicit: Bool = false) -> Date? {
        fade(now: now)

        let dismissed = Set(items.filter { $0.state == .dismissed }.map { LiveRailPacer.normalized($0.text) })
        let fullLanes = Set([LiveRailItem.Lane.now, .threads].filter { lane in
            items.filter { $0.lane == lane && $0.state == .pinned }.count >= pacer.cap(for: lane)
        })
        let admission = pacer.admit(
            candidates: items.filter { $0.state == .new },
            dismissed: dismissed,
            now: now,
            lastAdmitAt: lastAdmitAt,
            selfSpokeAt: selfSpokeAt,
            callType: callType,
            fullLanes: fullLanes,
            explicit: explicit
        )
        for id in admission.duplicatesOfDismissed {
            if let index = items.firstIndex(where: { $0.id == id }) {
                items[index].state = .dismissed
            }
        }
        for id in admission.stale {
            if let index = items.firstIndex(where: { $0.id == id }) {
                items[index].state = .expired
            }
        }
        if let id = admission.admitted, let index = items.firstIndex(where: { $0.id == id }) {
            items[index].state = .shown
            items[index].shownAt = now
            lastAdmitAt = now
            if explicit {
                requestedID = id
            }
            applyCap(items[index].lane)
        }

        var next: [Date] = items.compactMap { item in
            switch item.state {
            case .shown: item.shownAt.map { $0.addingTimeInterval(pacer.fadeAfter) }
            case .new: item.arrivedAt.addingTimeInterval(pacer.fadeAfter)
            case .pinned, .dismissed, .expired: nil
            }
        }
        if let retry = admission.retryAt {
            next.append(retry)
        }
        if admission.admitted != nil, waitingCount > 0, let lastAdmitAt {
            next.append(lastAdmitAt.addingTimeInterval(pacer.spacing))
        }
        return next.min()
    }

    /// Pinned items count toward the lane's cap but never fade; the oldest
    /// unpinned items fade to make room.
    private mutating func applyCap(_ lane: LiveRailItem.Lane) {
        let pinned = items.filter { $0.lane == lane && $0.state == .pinned }.count
        let shown = items.indices
            .filter { items[$0].lane == lane && items[$0].state == .shown }
            .sorted { (items[$0].shownAt ?? .distantPast) > (items[$1].shownAt ?? .distantPast) }
        for index in shown.dropFirst(max(0, pacer.cap(for: lane) - pinned)) {
            items[index].state = .expired
        }
    }

    private func visible(_ lane: LiveRailItem.Lane) -> [LiveRailItem] {
        items.filter { $0.lane == lane && ($0.state == .shown || $0.state == .pinned) }
            .sorted { ($0.shownAt ?? .distantPast) > ($1.shownAt ?? .distantPast) }
    }
}
