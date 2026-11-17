import SwiftUI
import MaughamCore

/// **Reference material arriving beside reveals the column that shows it**
/// (shell-finish stage 2b, final review's Critical).
///
/// The placement (`ProjectWindow.researchSubjectPlacement`, or
/// `figureSubjectPlacement` for a figure) decides WHICH column the item belongs
/// in; this decides that the column is on screen when it does. Beside, the
/// right column is the writer's only view of the item — so without this a
/// research row would write a subject that reaches no surface at all.
///
/// **An observer of the subject rather than a call at each writer.** The tree's
/// rows write the subject through a `List(selection:)` binding, so there is no
/// call site to add anything to; a rule keyed on the state covers the tree, the
/// find overlay's research match, and any future writer by construction. The
/// two forced entries call `revealResearchColumn` directly as well — see
/// `ProjectWindow.openResearchItem` for the case the observer cannot see.
struct ResearchRevealModifier: ViewModifier {
    /// The window's subject, `nil` until `load()` restores it — which is how
    /// the restore is told apart from an arrival.
    let subject: WindowSubject?
    @Binding var showInspector: Bool
    @Binding var detailSegment: DetailSegment

    func body(content: Content) -> some View {
        content
            .onChange(of: subject) { previous, next in
                // **A restored subject is not an arrival.** `ProjectWindow.load`
                // seeds the window's first subject from `UIState` — the one
                // write whose predecessor is no subject at all — and it lands
                // beside a `detailSegment` restored VERBATIM from the same state.
                // Revealing there would overwrite the writer's last explicit pane
                // choice on every reopen with a research item beside, which is
                // the opposite of what the restore path is careful to preserve.
                guard previous != nil, let next else { return }
                ProjectWindow.revealResearchColumn(
                    subject: next,
                    showInspector: &showInspector,
                    detailSegment: &detailSegment)
            }
    }
}
