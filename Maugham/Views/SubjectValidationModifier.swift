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
///
/// **A figure subject has a second way to die: parking** (report plan 8a).
/// Send to Research keeps the record and parks the figure in its stream, so
/// no manifest fingerprint can see it. While the subject is a figure, the
/// sweep also asks the stream (`DocumentStore.figureIsParked`) whenever a
/// figure trigger moves `DocumentStore.figureRevision` — here or on another
/// Mac — and repairs through the same `validSubject` with the answer.
struct SubjectValidationModifier: ViewModifier {
    let store: ProjectStore?
    let documentStore: DocumentStore?
    @Binding var selectedSubject: BinderSubject?

    func body(content: Content) -> some View {
        content
            .onChange(of: store.map {
                Self.fingerprint(of: $0.manifest.structure, research: $0.manifest.research,
                                 figures: $0.manifest.figures ?? [])
            }) {
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
                    subject, in: store.manifest.structure,
                    research: store.manifest.research,
                    figures: store.manifest.figures ?? [], parked: [])
            }
            // Keyed only while the subject is a figure, so no other subject
            // observes the figure revision.
            .task(id: parkCheckKey) { await repairIfParked() }
    }

    /// The parked question's trigger: the figure and the revision, nil for
    /// any other subject (no task).
    private var parkCheckKey: ParkCheckKey? {
        guard let figureId = selectedSubject?.figureID else { return nil }
        return ParkCheckKey(figureId: figureId, revision: documentStore?.figureRevision)
    }

    struct ParkCheckKey: Equatable {
        let figureId: String
        let revision: Int?
    }

    /// Ask the figure's stream whether it is parked; if it is, and the
    /// subject still names it, repair. An unreadable stream answers nothing
    /// (a figure that cannot be told apart is left as the writer chose it).
    private func repairIfParked() async {
        guard let store, let documentStore, let figureId = selectedSubject?.figureID,
              let parked = try? await documentStore.figureIsParked(figureId), parked,
              !Task.isCancelled, selectedSubject == .figure(figureId) else { return }
        selectedSubject = ProjectWindow.validSubject(
            .figure(figureId), in: store.manifest.structure,
            research: store.manifest.research,
            figures: store.manifest.figures ?? [], parked: [figureId])
    }

    /// The trigger: the SET of structure ids UNION the set of research ids,
    /// sorted together and hashed.
    ///
    /// **One fingerprint, not two.** A subject is either a structure item or a
    /// research item (never both), so a single sweep needs to fire on either
    /// tree changing shape — two separate `.onChange`s would be two places that
    /// can fall out of step about which one repairs a given subject kind, and
    /// palette cards live inside `manifest.research` (under the palette group),
    /// so the research half already covers them with no third tree to watch.
    ///
    /// **Blind to title, path, order and nesting by construction**, which is how
    /// a rename, a reorder and a drop cannot fire this. That is not a timing
    /// argument — `renameStructureItem`/`moveStructureItem` and their research
    /// counterparts (including `moveResearchItem`, a scope move) all preserve
    /// every id, so the value they produce is byte-identical and `.onChange`
    /// never sees a change to deliver. An `.onChange` that fired on those would
    /// be watching every intermediate state a multi-step mutation passes
    /// through, and clearing the writer's selection during a drag is a worse bug
    /// than the dangling subject this exists to fix — and a research subject
    /// must survive its own rescope exactly as a structure one survives a
    /// reparent.
    ///
    /// **A scalar, not the trees themselves.** `.onChange(of: structure)`
    /// compiles and compares every item and every title on every body pass;
    /// `CanvasItemIndex.fingerprint` is the same shape for the same reason and
    /// its comment carries the derivation. `StableHash.fnv1a64Hex` rather than
    /// `hashValue` because `hashValue` is process-seeded (SE-0206) and nothing
    /// here needed seeding — same walk, same cost, and no hole in
    /// `TripwireGrepTests.test_noHashValueInPersistedIdConstruction`.
    ///
    /// **Sorted before hashing, structure and research ids together.**
    /// `collectIds` is pre-order, so an unsorted join would move on a reparent
    /// or a rescope that changes no membership — the drop/move case, straight
    /// back. The two id spaces are joined into one sorted list rather than
    /// hashed separately and combined, so an id moving between the two trees
    /// (which does not happen today) could never cancel out against itself.
    ///
    /// **The figure registry's ids join them** (report plan 8a): a figure
    /// removed here or on another Mac leaves the registry, and a rename keeps
    /// its id, so the same blindness holds.
    static func fingerprint(
        of structure: [StructureItem], research: [ResearchItem], figures: [FigureRecord]
    ) -> String {
        // A control character, so no id can spell the separator and make two
        // different trees hash alike.
        let ids = TreeWalk.collectIds(in: structure) + TreeWalk.collectIds(in: research)
            + figures.map(\.id)
        return StableHash.fnv1a64Hex(ids.sorted().joined(separator: "\u{1}"))
    }
}
