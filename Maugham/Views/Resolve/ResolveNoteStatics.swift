import SwiftUI
import MaughamCore

// Moved from the Annotations pane's statics when that pane was deleted
// (shell plan 2 Task 7): what a refused note verb says, and whether the bulk
// bar has a verb to offer.
extension ResolveNoteVerbs {
    /// **A refused Reopen / Restore is SAID** (P3c plan 2 Task 8). The pane
    /// used to hand `reopenAnnotation` a bare `try?`, so a Restore the door
    /// refused — a Delete that is not hers to undo, drawn a frame before the
    /// refusal was knowable — did nothing at all (RULING-22's shape). The
    /// refusal's own sentence now goes to the window's notice channel
    /// (`MaughamEvent.postNotice`, the house path;
    /// the translation pane's reply's shape) and comes back to the caller.
    @MainActor
    @discardableResult
    static func sayRefused(_ error: Error, in document: Document) -> String {
        sayRefused(error, projectURL: document.opStore.projectURL)
    }

    /// The same, for a press with no `Document` behind it — a figure note's
    /// answer (report plan 9c-1 Task 7), whose refusals (`FigureNoteError`,
    /// a parked figure, a permit) are sentences the writer is told, never
    /// swallowed.
    @MainActor
    @discardableResult
    static func sayRefused(_ error: Error, projectURL: URL) -> String {
        let sentence = error.localizedDescription
        MaughamEvent.postNotice(sentence, projectURL: projectURL)
        return sentence
    }

    /// Whether any bulk verb survives this document's posture (P3c Task 5).
    static func bulkOffersAVerb(posture: Posture) -> Bool {
        [AnnotationBulkActions.BulkVerb.accept, .stet, .triage(nil)]
            .contains { AnnotationBulkActions.offers($0, under: posture) }
    }
}
