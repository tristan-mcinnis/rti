import Foundation
import Observation
import RTICore

/// The active call type, remembered between launches.
@Observable @MainActor
final class CallTypeStore {
    static let shared = CallTypeStore(
        active: CallType.resolve(stored: UserDefaults.standard.string(forKey: CallTypeDefaults.activeKey)),
        defaults: .standard
    )

    /// Nil in a memory-only store, so a test or proof never changes the
    /// user's live choice.
    @ObservationIgnored private let defaults: UserDefaults?

    var active: CallType {
        didSet { defaults?.set(active.rawValue, forKey: CallTypeDefaults.activeKey) }
    }

    private init(active: CallType, defaults: UserDefaults?) {
        self.active = active
        self.defaults = defaults
    }

    static func inMemory(_ active: CallType = .client) -> CallTypeStore {
        CallTypeStore(active: active, defaults: nil)
    }
}
