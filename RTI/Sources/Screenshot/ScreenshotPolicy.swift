import Foundation
import Observation
import RTICore

enum ScreenshotMode: String, CaseIterable, Identifiable {
    case off
    case manual
    case automatic

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .off: "Off"
        case .manual: "Manual only"
        case .automatic: "Automatic during recording"
        }
    }
}

@Observable @MainActor
final class ScreenshotPolicy {
    static let shared = ScreenshotPolicy(defaults: .standard)
    private static let globalKey = "rti.screenshots.mode"
    private static let projectsKey = "rti.screenshots.projectModes"

    private(set) var global: ScreenshotMode
    private var overrides: [String: [String: String]]
    private(set) var generation = 0
    private var automaticGeneration = 0
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        global = defaults.string(forKey: Self.globalKey).flatMap(ScreenshotMode.init(rawValue:)) ?? .manual
        overrides = defaults.dictionary(forKey: Self.projectsKey) as? [String: [String: String]] ?? [:]
    }

    var project: String? {
        guard let item = MeetingContextStore.shared.workstreamItem, item.isProject else { return nil }
        return item.id
    }

    var projectOverride: ScreenshotMode? {
        override(project: project, callType: CallTypeStore.shared.active)
    }

    var effective: ScreenshotMode {
        effective(project: project, callType: CallTypeStore.shared.active)
    }

    func override(project: String?, callType: CallType) -> ScreenshotMode? {
        guard let project, let raw = overrides[project]?[callType.rawValue] else { return nil }
        return ScreenshotMode(rawValue: raw)
    }

    func effective(project: String?, callType: CallType) -> ScreenshotMode {
        global == .off ? .off : (override(project: project, callType: callType) ?? global)
    }

    func setGlobal(_ mode: ScreenshotMode) {
        guard mode != global else { return }
        global = mode
        defaults.set(mode.rawValue, forKey: Self.globalKey)
        changed()
    }

    func setOverride(_ mode: ScreenshotMode?, project: String, callType: CallType) {
        guard mode != override(project: project, callType: callType) else { return }
        var modes = overrides[project] ?? [:]
        modes[callType.rawValue] = mode?.rawValue
        overrides[project] = modes.isEmpty ? nil : modes
        defaults.set(overrides, forKey: Self.projectsKey)
        changed()
    }

    /// A quick choice edits the active project's override when it has one.
    func choose(_ mode: ScreenshotMode) {
        if let project, projectOverride != nil {
            setOverride(mode, project: project, callType: CallTypeStore.shared.active)
            if global == .off, mode != .off {
                setGlobal(mode)
            }
        } else {
            setGlobal(mode)
        }
    }

    func changed() {
        generation &+= 1
        guard self === Self.shared else { return }
        ScreenshotManager.shared.invalidateCapture()
        VisualContextTrail.shared.refreshPolicy()
    }

    func automaticStateChanged() {
        automaticGeneration &+= 1
    }

    enum Purpose { case manual, automatic }

    struct Permit {
        let generation: Int
        let automaticGeneration: Int
        let sessionID: String?
        let excluded: Set<String>
        let purpose: Purpose
    }

    func allows(_ purpose: Purpose) -> Bool {
        switch purpose {
        case .manual: effective != .off
        case .automatic: effective == .automatic && SessionCoordinator.shared.phase == .recording
        }
    }

    func permit(for purpose: Purpose) throws -> Permit {
        guard allows(purpose) else { throw ScreenshotError.disabled }
        return Permit(generation: generation, automaticGeneration: automaticGeneration, sessionID: SessionCoordinator.shared.currentSessionId, excluded: ScreenPrivacy.blockedBundleIDs, purpose: purpose)
    }

    func check(_ permit: Permit) throws {
        try Task.checkCancellation()
        guard permit.purpose == .manual || permit.automaticGeneration == automaticGeneration, generation == permit.generation, SessionCoordinator.shared.currentSessionId == permit.sessionID,
              ScreenPrivacy.blockedBundleIDs == permit.excluded, allows(permit.purpose) else { throw CancellationError() }
    }
}
