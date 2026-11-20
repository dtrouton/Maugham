import SwiftUI
import MaughamCore

/// **The right column follows the subject** (shell plan 3 Task 9; it began as
/// the research reveal of shell-finish stage 2b, final review's Critical).
///
/// Three things, one observer of the subject:
/// - **the position after a subject change**
///   (`RightColumnContent.positionAfterSubjectChange`): something newly pulled
///   up shows the pulled-up position; that position left with nothing to show
///   goes back to the face before it; the faces moving onto the canvas show
///   its details;
/// - **the reveal**: something ARRIVING pulled up shows the column, or a
///   research row in the tree would write a subject that reaches no surface;
/// - **the remembered position**: `UIState.rightColumnPosition`'s one writer,
///   and `previousFace`'s.
///
/// **An observer of the subject rather than a call at each writer.** The tree's
/// rows write the subject through a `List(selection:)` binding, so there is no
/// call site to add anything to; a rule keyed on the state covers the tree, the
/// find overlay's research match, and any future writer by construction. The
/// forced entries call `ProjectWindow.revealPulledUp` as well — see
/// `ProjectWindow.openResearchItem` for the case the observer cannot see.
struct ResearchRevealModifier: ViewModifier {
    /// The window's subject, `nil` until `load()` restores it — which is how
    /// the restore is told apart from a change.
    let subject: WindowSubject?
    @Binding var showInspector: Bool
    @Binding var position: RightColumnPosition
    @Binding var previousFace: RightColumnPosition
    let store: ProjectStore?
    let documentStore: DocumentStore?

    func body(content: Content) -> some View {
        content
            .onChange(of: subject) { previous, next in
                // **A restored subject is not a change.** `ProjectWindow.load`
                // seeds the window's first subject from `UIState` — the one
                // write whose predecessor is no subject at all — beside a
                // position restored VERBATIM from the same state. Moving the
                // position there would overwrite the writer's last choice on
                // every reopen.
                guard let previous, let next else { return }
                let after = RightColumnContent.positionAfterSubjectChange(
                    position, from: previous, to: next, previousFace: previousFace,
                    structure: store?.manifest.structure ?? [],
                    projectType: store?.manifest.type ?? .novel)
                if after != position { position = after }
                if Self.reveals(from: previous, to: next) { showInspector = true }
            }
            .onChange(of: position) { _, new in
                previousFace = Self.previousFace(previousFace, after: new)
                documentStore?.updateUIState { $0.rightColumnPosition = new }
            }
    }

    /// **Only something ARRIVING pulled up reveals.** `beside` persists
    /// across clicks (the click rule), so a change that leaves it as it was —
    /// the faces moving to a chapter, the Book opening — is not an arrival, and
    /// revealing on it would reopen a column the writer closed on every click
    /// after the first. The restore (from `nil`) is not an arrival either, and
    /// nor is putting what was beside away (shell p1 final fix). Something
    /// already beside that a navigation makes the part clicked last again
    /// (`ClickRule.navigate`) is: the writer asked to be shown it.
    static func isAnArrival(from previous: WindowSubject?, to next: WindowSubject?) -> Bool {
        guard let previous, let next, next.beside != nil else { return false }
        return next.beside != previous.beside
            || (next.besideIsLatest && !previous.besideIsLatest)
    }

    /// Whether a subject change shows the column: an arrival the right column
    /// is where to see (`pulledUpIsShownBeside` — never an item the centre
    /// already shows).
    static func reveals(from previous: WindowSubject?, to next: WindowSubject?) -> Bool {
        guard isAnArrival(from: previous, to: next), let next else { return false }
        return ProjectWindow.pulledUpIsShownBeside(subject: next)
    }

    /// The face to go back to, after the position became `new`: the last
    /// position that was not the pulled-up one.
    static func previousFace(_ current: RightColumnPosition,
                             after new: RightColumnPosition) -> RightColumnPosition {
        new == .pulledUp ? current : new
    }
}
