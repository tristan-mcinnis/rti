import AppKit
import AVFoundation
import Foundation
import Observation
import RTICore

extension SessionCoordinator {
    /// Only a visible reader needs text layout. A token prevents a retired
    /// view's delayed disappearance from deactivating its replacement.
    func activateTranscriptPresentation(for owner: UUID) {
        transcriptPresentationOwner = owner
        // Options and names may have changed before the first visit, when no
        // Transcript view existed to observe them.
        refreshTranscriptPresentation()
    }

    func deactivateTranscriptPresentation(for owner: UUID) {
        if transcriptPresentationOwner == owner {
            transcriptPresentationOwner = nil
        }
    }

    /// Copy the same ordered, committed runs the reader already projected.
    /// Formatting is the only traversal; no layout or provisional state changes.
    func transcriptTextForCopy() -> String {
        LiveTranscriptPresentation.copyText(rows: transcriptProjection.committedRows)
    }

    /// Raw transcript publication continues while hidden. Finals are marked
    /// dirty, and the next visible reader projects the latest snapshot once.
    func refreshTranscriptPresentation(finalsChanged: Bool = true) {
        transcriptFinalsNeedProjection = transcriptFinalsNeedProjection || finalsChanged
        guard transcriptPresentationOwner != nil else { return }
        if transcriptFinalsNeedProjection {
            let names = SpeakerNameStore.shared.names
            let translate = TranslationStore.currentConfig() != nil
            if usesSeededTranscript {
                transcriptProjection.updateFinals(liveEntries, names: names, showTranslations: translate)
            } else {
                transcriptProjection.updateLiveFinals(transcriptPipeline, names: names, showTranslations: translate,
                                                     labelsEnabled: speakerPolicy.liveLabelsEnabled)
            }
            transcriptFinalsNeedProjection = false
        }
        transcriptRows = transcriptProjection.updateInterims(interimSegments)
        transcriptTurns = transcriptProjection.turns(for: transcriptRows)
        transcriptDisplayRevision += 1
    }
}
