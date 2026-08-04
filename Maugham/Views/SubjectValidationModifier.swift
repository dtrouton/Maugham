import SwiftUI
import MaughamCore

/// Keeps the window's subject naming a row that is still there.
///
/// **Keyed on the structure, not on the deletion.** The rule this replaces lived
/// in `BinderView.deleteItem` and asked *"is the subject the row I deleted?"* —
/// which is the same question as *"is the subject still in the structure?"* for
/// a document and a different one for a group, because `TreeWalk.remove` takes
/// a group's children with it and the selected child's id is not the group's.
/// It was also only reachable from one of the three sites that call
/// `ProjectStore.deleteStructureItem`: `CollectionPiecesPane` and
/// `ReferencePieceInspector` delete a piece with no repair at all, so on a
/// Collection the direct case dangled too.
///
/// Watching the structure has nothing for a caller to remember, and it covers
/// the deletions no list of sites can: a cross-device op-log merge, an external
/// edit, whatever the next mutation turns out to be.
///
/// **What a dangling subject becomes is `.project`, and it is the same answer
/// the restore gives** — `ProjectWindow.validSubject` is called here rather than
/// re-derived. `nil` and `.project` both leave the canvas undimmed, so the
/// canvas cannot tell them apart; the editor, History and Tasks can, and they
/// show the same empty state for both (`activeItemID` is nil either way). What
/// decides it is that these are one question asked twice: deleting the selected
/// chapter and deleting it then relaunching must land the window in the same
/// place, and the restore's ruling — *a subject nobody chose is `.project`* —
/// already fixed that place. `nil` would also leave the binder with no row
/// highlighted, which is a state the project row exists to make unnecessary.
struct SubjectValidationModifier: ViewModifier {
    let store: ProjectStore?
    @Binding var selectedSubject: BinderSubject?

    func body(content: Content) -> some View {
        content
            .onChange(of: store.map { Self.fingerprint(of: $0.manifest.structure) }) {
                oldValue, newValue in
                // The structure APPEARING is not the structure changing, and nor
                // is it vanishing. `load()` sets `store` and then awaits before
                // it sets the subject, so a body pass lands in between with the
                // store already in place — and a sweep in that window would
                // write `.project` through `updateUIState` into the very
                // `ds.uiState.selectedSubject` that `load()` has not read yet,
                // making every reopen land on the project row. `.onDisappear`
                // is the mirror image on the way out.
                guard oldValue != nil, newValue != nil else { return }
                guard let store, let subject = selectedSubject else { return }
                // A sweep REPAIRS a subject; it does not choose one. Promoting
                // `nil` here would move a window whose writer deliberately
                // clicked into empty space, on a delete somewhere else in the
                // tree. Choosing is the restore's job and the writer's.
                selectedSubject = ProjectWindow.validSubject(
                    subject, in: store.manifest.structure)
            }
    }

    /// The trigger: the SET of structure ids, sorted and hashed.
    ///
    /// **Blind to title, path, order and nesting by construction**, which is how
    /// a rename, a reorder and a drop cannot fire this. That is not a timing
    /// argument — `renameStructureItem` and `moveStructureItem` both preserve
    /// every id, so the value they produce is byte-identical and `.onChange`
    /// never sees a change to deliver. An `.onChange` that fired on those would
    /// be watching every intermediate state a multi-step mutation passes
    /// through, and clearing the writer's selection during a drag is a worse bug
    /// than the dangling subject this exists to fix.
    ///
    /// **A scalar, not the structure itself.** `.onChange(of: structure)`
    /// compiles and compares every item and every title on every body pass;
    /// `CanvasItemIndex.fingerprint` is the same shape for the same reason and
    /// its comment carries the derivation. `StableHash.fnv1a64Hex` rather than
    /// `hashValue` because `hashValue` is process-seeded (SE-0206) and nothing
    /// here needed seeding — same walk, same cost, and no hole in
    /// `TripwireGrepTests.test_noHashValueInPersistedIdConstruction`.
    ///
    /// **Sorted before hashing.** `collectIds` is pre-order, so an unsorted join
    /// would move on a reparent that changes no membership — the drop case,
    /// straight back.
    static func fingerprint(of structure: [StructureItem]) -> String {
        // A control character, so no id can spell the separator and make two
        // different structures hash alike.
        StableHash.fnv1a64Hex(
            TreeWalk.collectIds(in: structure).sorted().joined(separator: "\u{1}"))
    }
}
