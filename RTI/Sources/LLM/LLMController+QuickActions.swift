import AppKit
import Foundation
import HouseChatCore
import HouseChatDocuments
import Observation
import RTICore

// MARK: - Mode-aware quick actions

extension LLMController {
    /// The assistant actions to surface in the ✦ menu for the current mode +
    /// listener state — projected from the single `AssistantAction.all`
    /// catalogue (no per-surface registry). The ✦ menu runs each via
    /// `perform(actionID:)`.
    func availableQuickActions() -> [AssistantAction] {
        let kind = modeStore.activeMode?.kind ?? .other
        let listener = listenerMode
        return AssistantAction.all.filter { action in
            if let lo = action.listenerOnly, lo != listener { return false }
            if let modes = action.modes, !modes.contains(kind) { return false }
            return true
        }
    }

    /// The ambient OCR trail this turn carries, or nil when nothing is
    /// recording. The send and the composer's label read this one function, so
    /// a screen block on the wire is always named before Send.
    func ambientScreenRead() -> String? {
        if let ambientScreenProvider { return ambientScreenProvider() }
        return SessionCoordinator.shared.isRunning
            ? VisualContextTrail.shared.recentPromptContext()
            : nil
    }

    /// Compact, user-facing description of the context the next assistant turn
    /// can see. Mirrors `performSend` without exposing prompt internals.
    ///
    /// It takes the same two inputs the image preview and the withheld notice
    /// take, the actual draft `question` and the composer's fresh source ids, and
    /// reads the same `previewWire`. A comparison question therefore names the
    /// retained sources it will send, and a pending dated hand-over is treated as
    /// the fresh source it is. A count alone could not know either.
    func contextPreviewLabels(question: String, freshSourceIDs: [String]) -> [String] {
        let (wire, _) = previewWire(question: question, freshSourceIDs: freshSourceIDs)
        return ContextDisclosureLabels.make(ContextDisclosureInput(
            hasLiveTranscript: SessionCoordinator.shared.liveEntries.contains {
                $0.translationStatus != "translation"
                    && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            },
            workstreamName: MeetingContextStore.shared.workstreamName,
            hasMeetingNote: !MeetingContextStore.shared.note
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            hasBrief: MeetingContextStore.shared.briefContext != nil,
            glossaryEntryCount: GlossaryStore.shared.entries.count,
            hasPendingScreenCapture: pendingScreenContext != nil,
            // The same read `performSend` makes, so the label and the screen
            // block cannot disagree.
            hasAmbientScreenRead: ambientScreenRead().map {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            } == true,
            retainedSourceNames: wire.carriesRetainedSources ? retainedSourceNames : [],
            datedSourceName: pendingDatedSourceName
        ))
    }

    /// The chat's retained sources, by display name, for the composer's own
    /// footnote. Never a path: the composer names sources the way the chips do.
    var retainedSourceNames: [String] {
        retainedSources.map { source in
            let name = source.document?.name ?? (source.path as NSString).lastPathComponent
            return name.isEmpty ? (source.path as NSString).lastPathComponent : name
        }
    }

    /// Why the next turn cannot reach the vault, in one line, or nil when it
    /// can (or carries no source at all). The composer shows it before Send and
    /// points at the existing Broader Search row; nothing is hidden, and the
    /// tool policy itself is unchanged.
    func vaultWithheldNotice(question: String, freshSourceIDs: [String]) -> String? {
        let (wire, _) = previewWire(question: question, freshSourceIDs: freshSourceIDs)
        guard wire.carriesSources, !wire.decision.allowsExternalRetrieval else { return nil }
        return ContextDisclosureLabels.vaultWithheldLine
    }

    /// The wire the composer state would send, from ONE id set: the composer's
    /// own fresh sources plus the dated hand-over this controller holds. The
    /// image preview, the withheld notice and the context labels all read this,
    /// so the preview cannot compose a different source set than the send.
    func previewWire(
        question: String,
        freshSourceIDs: [String]
    ) -> (wire: ChatWireSources, freshIDs: Set<String>) {
        var ids = freshSourceIDs
        if let dated = pendingDatedSources.first {
            ids.append(Self.sourceID(dated))
        }
        let freshIDs = Set(ids)
        let wire = ChatWireSources.compose(
            question: question,
            freshSourceCount: freshIDs.count,
            retainedSourceCount: retainedSources.count,
            historyTurnCount: entries.filter { $0.role == "user" }.count,
            historyHasSources: entries.contains { $0.role == "user" && !$0.attachments.isEmpty },
            broaderToggleOn: broaderSearchEnabled
        )
        return (wire, freshIDs)
    }
}
