import SwiftUI
import MaughamCore

/// The inspector's one Intent affordance (M1A Task 8, spec §4.3).
///
/// **One affordance, not two.** It replaces the craft-intent seam's pair —
/// "Open Craft Intent" when a doc existed, "Add craft intent…" when it did not,
/// the second of which *minted a research note* on press. There is nothing to
/// add here now: the Intent pane's own rule is that absence is valid and an
/// empty scope shows an empty editor that mints on the first keystroke, so a
/// separate "Add" button would be the nag the pane deliberately does not have.
/// The row says whether the scope has an intent and offers to go to it.
///
/// **Shared by both inspectors on purpose.** `InspectorView` (the manuscript
/// inspector) and `PieceInspector` (a Collection loose piece) each carried their
/// own copy of the old pair, and the two were kept in step by hand. One view
/// means the button, the caption and the scope resolution cannot come to
/// different conclusions about what the writer is about to see.
struct IntentAffordanceRow: View {

    let store: ProjectStore
    /// The binder selection, exactly as `ProjectWindow` hands it to the right
    /// column (`activeDocId`, `ProjectWindow.swift`'s `inspectorPane`). For
    /// `PieceInspector` that is the piece's own id, which is the same value.
    let selectedItemId: String?

    /// The button's label. Named so the test that presses it and the view that
    /// draws it cannot drift.
    static let openTitle = "Open Intent"

    /// The scope the Intent pane will show for this selection.
    ///
    /// **`StatementPane`'s own resolution, not a second one.** The pane's scope
    /// follows the binder selection (§4.3), so with a chapter selected this
    /// button lands on the *chapter's* intent and not the project's — and a
    /// caption derived any other way would describe a scope the writer is not
    /// about to be shown.
    ///
    /// It used to pass `prefersProjectScope: false` — "what a fresh arrival
    /// shows", the inspector declining to guess at pane state it cannot see.
    /// The pane has no such state as of the persona shell's slice 1: its scope
    /// switch is gone and the tree is the one subject-picker, so there is
    /// nothing left for this row to be out of step with.
    ///
    /// A `nil` id is *no selection*, which resolves to the project — the same
    /// answer `BinderSubject.project` gets. This row is removed in slice 4, when
    /// the inspector dissolves.
    static func scope(selectedItemId: String?,
                      in structure: [StructureItem]) -> Statement.Scope {
        StatementPane.effectiveScope(
            kind: .intent, subject: selectedItemId.map(BinderSubject.item),
            structure: structure)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(Self.openTitle) { MaughamEvent.postDetailSegment(.intent) }
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var caption: String {
        let scope = Self.scope(
            selectedItemId: selectedItemId, in: store.manifest.structure)
        let subject: String = {
            if case .document(let id) = scope,
               let item = TreeWalk.find(id: id, in: store.manifest.structure) {
                return item.title
            }
            return store.manifest.title
        }()
        return store.statement(kind: .intent, scope: scope) == nil
            ? "Nothing written for “\(subject)” yet"
            : "For “\(subject)”"
    }
}
