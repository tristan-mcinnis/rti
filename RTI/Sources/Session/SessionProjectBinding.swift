import Foundation

/// Owns the sticky project-selection state and project↔session membership
/// writes. Extracted from `SessionCoordinator` so the project-binding
/// concern (UserDefaults, ProjectStore membership, cross-launch stickiness)
/// lives in one place instead of interleaving through a 591-line class.
///
/// `SessionCoordinator` forwards `activeProjectId` through this store so
/// existing callers (`LLMController`, views) see no change.
@MainActor
final class SessionProjectBinding: ObservableObject {
    nonisolated static let shared = SessionProjectBinding()

    @Published private(set) var activeProjectId: String?

    private nonisolated static let activeProjectKey = "rti.session.activeProjectId"

    nonisolated private init() {
        let stored = UserDefaults.standard.string(forKey: Self.activeProjectKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Use Task to hop onto MainActor for the isolated property write.
        Task { @MainActor in
            self.activeProjectId = (stored?.isEmpty == false) ? stored : nil
        }
    }

    /// Set (or clear) the project the current session is associated with.
    func setActiveProject(_ projectId: String?, forSessionId sessionId: String?) {
        let normalized = projectId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let newValue: String? = (normalized?.isEmpty == false) ? normalized : nil
        guard newValue != activeProjectId else { return }

        if let sessionId {
            for project in ProjectStore.shared.projects {
                if project.id != newValue {
                    ProjectStore.shared.removeSession(sessionId, fromProject: project.id)
                }
            }
            if let newValue {
                ProjectStore.shared.addSession(sessionId, toProject: newValue)
            }
        }

        activeProjectId = newValue
        if let newValue {
            UserDefaults.standard.set(newValue, forKey: Self.activeProjectKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.activeProjectKey)
        }

        let name = newValue.flatMap { id in
            ProjectStore.shared.projects.first { $0.id == id }?.name
        } ?? "(none)"
        RTILog.log("active project → \(name)", category: "projects")
    }

    /// Query `project_sessions` for the given session id and update
    /// `activeProjectId` to match.
    func refreshMembership(for sessionId: String) {
        let projects = ProjectStore.shared.projects
        for project in projects {
            if ProjectStore.shared.sessionIds(forProject: project.id).contains(sessionId) {
                if activeProjectId != project.id {
                    activeProjectId = project.id
                    UserDefaults.standard.set(project.id, forKey: Self.activeProjectKey)
                }
                return
            }
        }
    }

    /// Register the given session as a member of the sticky project so
    /// pre-recording Q&A inherits the project's instructions.
    func carryOverToNewSession(_ sessionId: String) {
        guard let pid = activeProjectId else { return }
        ProjectStore.shared.addSession(sessionId, toProject: pid)
    }
}
