import SwiftUI
import AppKit

/// **Denver's travel rule, 2026-08-12: a double-click on any tree row in Plan
/// takes the writer to Author, on that row's subject.**
///
/// Plan's centre column is always the planning canvas (`Persona
/// .centresTheCanvas`) — a chapter, a research note, a palette card double-
/// clicked in the tree has nowhere to open *in* Plan, so the writer has to be
/// taken to where it opens. Elsewhere the tree already sits beside the
/// document it names (Author, Review, Publish all centre the editor), so the
/// same double-click means nothing beyond the click a single click already
/// gave it — no persona to travel TO.
///
/// **Two halves, one file** (the plan's own instruction): `treeTravelOnDoubleClick(_:)`
/// is the poster, attached to a row's LABEL LEAF — never the row container,
/// which is tripwire 9's exact scar. `TaskRow.swift`'s own doc comment records
/// it: an earlier `.simultaneousGesture(TapGesture(count: 2))` on the whole row
/// made SwiftUI wait to see whether a press would resolve as a double-click,
/// eating drag initiation across the row's interior — the writer could only
/// drag from the row's padding, never its body text. So every row this rule
/// touches carries the gesture on its Text/Label alone, leaving `.draggable` /
/// `.dropDestination` on the row's own container untouched.
///
/// **The subject posted is the row's OWN tag, never `state.selection`** (T3's
/// standing rule) — a double-click fires before `List(selection:)`'s own
/// write-back is guaranteed to have landed, so reading the selection back
/// would be racing the very click that is supposed to be authoritative.
///
/// `TreeTravelModifier` is the receiver, mounted once on `ProjectWindow.body`.
/// It writes `selectedSubject` directly and moves the persona through
/// `PersonaModifier.applyPersonaChange` — the same call `ManuscriptNavigation
/// .go` makes and for the same reason: a deliberate writer move records the
/// departing position, so ⌘1 brings the writer back to the tree they were
/// arranging. **Not through `ManuscriptNavigation` itself** — that rule reads
/// "does the CURRENT persona already show a manuscript document", which is a
/// different question from "is Plan the departure point", and answering the
/// travel rule by routing it through a navigation meant for a different
/// premise would leave Review's own guard (never eject a reviewer mid-
/// adjudication) silently deciding a case it was never asked about.
enum TreeTravel {

    /// Where a double-click on a tree row takes the window, or `nil` when it
    /// takes it nowhere.
    ///
    /// **`persona.centresTheCanvas`, not `== .plan`** — the same discriminator
    /// `ManuscriptNavigation` uses and for the same reason
    /// (`ManuscriptNavigationTests.test_theRuleIsAboutTheCentreColumn_notAboutAnyParticularPersona`):
    /// the travel rule is about *"is there a persona to travel to"*, not about
    /// which one is named Plan today.
    static func treeTravelDestination(persona: Persona) -> Persona? {
        guard persona.centresTheCanvas else { return nil }
        return .author
    }
}

extension View {
    /// Attach to a row's LABEL LEAF only — see `TreeTravel`'s doc comment for
    /// why the container is never the right place. Posts the row's own
    /// `subject`, unconditionally: the persona guard lives on the RECEIVER
    /// (`TreeTravel.treeTravelDestination`), so a double-click in Author still
    /// posts and is refused there — one control point, not a second copy of
    /// the guard at every call site.
    func treeTravelOnDoubleClick(_ subject: BinderSubject) -> some View {
        onTapGesture(count: 2) {
            MaughamEvent.post(.maughamTreeTravel, to: .keyWindow,
                              payload: [MaughamEvent.treeTravelSubjectKey: subject])
        }
    }
}

/// The mounted receiver — one line on `ProjectWindow.body`
/// (`Maugham/Views/AREA.md`'s established shape: window behaviour lives in a
/// `ViewModifier` because that body is at SwiftUI's type-checker ceiling).
/// Deleting the mount line leaves every token in this file present and every
/// pure-function test green while a double-click reaches nobody — the same
/// failure mode `CanvasClaudeArrivalModifier`'s own doc comment warns about.
struct TreeTravelModifier: ViewModifier {
    let window: NSWindow?
    @Binding var persona: Persona
    @Binding var detailSegment: DetailSegment
    @Binding var selectedSubject: BinderSubject?
    let documentStore: DocumentStore?

    func body(content: Content) -> some View {
        content
            .onKeyWindowCommand(.maughamTreeTravel, window: window) { note in
                guard let subject = note.userInfo?[MaughamEvent.treeTravelSubjectKey]
                        as? BinderSubject,
                      let destination = TreeTravel.treeTravelDestination(persona: persona)
                else { return }
                selectedSubject = subject
                let change = PersonaModifier.applyPersonaChange(
                    to: destination,
                    from: persona,
                    currentSegment: detailSegment,
                    memory: documentStore?.uiState.personaMemory ?? .empty)
                persona = change.persona
                detailSegment = change.segment
                documentStore?.updateUIState {
                    $0.persona = change.persona
                    $0.personaMemory = change.memory
                }
            }
    }
}
