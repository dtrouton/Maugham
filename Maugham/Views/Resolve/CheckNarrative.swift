import SwiftUI
import MaughamCore

/// **The check's narrative — what a check's findings say and what may be done
/// to them, without a pane** (shell plan 2 Task 7).
///
/// The Diagnostics pane was deleted when To resolve took the right column:
/// a check's strains are findings in that one list, and its letter, its
/// header and its drift line are To resolve's head. What the pane decided —
/// the header's state and copy, the wet-ink standing, the cold-start offer,
/// which verbs a posture offers, the Answer and Promote acts — lives on here
/// as pure statics, each a test without a mount. A namespace, never a view.
///
/// The clause readings (holds / strains / silent beside each intent sentence)
/// are not drawn anywhere until Brief marks them on the intent (shell plan 3);
/// the strains are findings meanwhile.
@MainActor
enum CheckNarrative {
    /// **Promote to Task, on the checked piece's own live `Document`** — a
    /// static so To resolve calls the same act (shell plan 2 Task 4). The
    /// caller hands the editor's document for the open piece, never a loaded
    /// one; the finding is dismissed from that piece's sidecar.
    static func promote(
        _ diagnostic: Diagnostic, run: CompilerRun?, in document: Document,
        diagnostics: DiagnosticsStore, undoManager: UndoManager?
    ) {
        document.createPaneTask(
            body: DiagnosticPromotion.taskBody(for: diagnostic, run: run),
            parentTaskId: nil,
            paragraphId: diagnostic.anchor?.paragraphId,
            undoManager: undoManager)
        diagnostics.dismiss(diagnostic.id, docId: document.docId)
    }
}

// MARK: - The posture (P3c Task 7)

/// **What a window may offer on the check's findings** — two questions,
/// because the verbs write to two places. `document` is the checked
/// piece's own posture (Got it / Not this settle its notes); `statement`
/// answers for whichever statement a verb would file a ruling in (an Answer,
/// the letter's *Add to intent*, the ledger's presses), at the ruling door's
/// own id (`DocumentStore.posture(ofStatement:scope:statements:)`), so the verb
/// To resolve hides and the ruling `RulingPerformer` refuses are one question.
struct DiagnosticsPostures {
    let document: Posture
    let statement: (Statement.Kind, Statement.Scope) -> Posture
}
