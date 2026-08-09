import SwiftUI
import MaughamCore

/// **A research subject arriving in Plan reveals the column that shows it**
/// (shell-finish stage 2b, final review's Critical).
///
/// The placement (`ProjectWindow.researchSubjectPlacement`) decides WHICH column
/// the item belongs in; this decides that the column is on screen when it does.
/// Beside the canvas the right column is the writer's only view of the item, and
/// Plan opens on `.inbox` — so without this a research row in Plan's tree writes
/// a subject that reaches no surface at all.
///
/// **An observer of the subject rather than a call at each writer.** The tree's
/// rows write `selectedSubject` through a `List(selection:)` binding, so there is
/// no call site to add anything to; a rule keyed on the state covers the tree,
/// the find overlay's research match, and any future writer by construction. The
/// two forced entries call `revealResearchColumn` directly as well — see
/// `ProjectWindow.openResearchItem` for the case the observer cannot see.
struct ResearchRevealModifier: ViewModifier {
    /// The window's working mode. Read, never written: revealing is about the
    /// columns, and which persona the writer is in is their own choice.
    let persona: Persona
    @Binding var selectedSubject: BinderSubject?
    @Binding var showInspector: Bool
    @Binding var detailSegment: DetailSegment

    func body(content: Content) -> some View {
        content
            .onChange(of: selectedSubject) { previous, next in
                // **A restored subject is not an arrival.** `ProjectWindow.load`
                // seeds the window's first subject from `UIState` — the one
                // write whose predecessor is no subject at all, since
                // `validSubject` always answers (`.project` needs nothing to
                // exist) — and it lands beside a `detailSegment` restored
                // VERBATIM from the same state. Revealing there would overwrite
                // the writer's last explicit pane choice on every reopen with a
                // research subject in it, which is the opposite of what the
                // restore path is careful to preserve. A reveal is about a
                // subject arriving while the writer is here.
                guard previous != nil else { return }
                ProjectWindow.revealResearchColumn(
                    persona: persona, subject: next,
                    showInspector: &showInspector,
                    detailSegment: &detailSegment)
            }
    }
}
