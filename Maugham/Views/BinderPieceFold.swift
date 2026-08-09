import SwiftUI
import MaughamCore

/// **The rows under a folded piece row** (shell-finish stage-2a Task 6, spec §3).
///
/// A piece row that has research of its own unfolds to it, so the writer sees
/// what a chapter or a piece is carrying without leaving the one left column the
/// milestone gives every persona. The *rule* for which documents fold, and for
/// what a fold contains, is not here: it is `TreeSectionDerivation.pieceFold`,
/// pure and asked per render (tripwire 4 — a manifest walk, never disk). This
/// view is only how those items are drawn, and it is one implementation for both
/// hosts (`BinderView`, `CollectionPiecesPane`) for the same reason
/// `BinderTreeSections` is one: a copy drifts.
///
/// **The two semantics draw differently, and the difference is real.** A
/// collection piece's fold is *containment* — those items live in the piece's
/// own `research/` folder, so a group in there is a group of the piece's
/// research and expands like one. A novel chapter's fold is *links*, and a
/// linked group's children are not linked to that chapter by anything; expanding
/// one would show them as the chapter's research on a link nothing recorded. So
/// `.linked` folds render flat (`ResearchTreeNode.expandsGroups`).
///
/// **It is mounted inside a `DisclosureGroup` by the host**, never on its own:
/// the chevron belongs to the piece row, which stays the unchanged
/// `BinderRow`/`PieceRow` — still draggable, still renamable — because the fold
/// must not cost the row any of what it already does.
struct BinderPieceFold: View {
    @Bindable var store: ProjectStore
    @Bindable var state: BinderTreeSectionsState
    @Binding var selectedSubject: BinderSubject?
    /// The document this fold hangs under — and the *scope* a note made from a
    /// row in it belongs to. See `actions`.
    let documentId: String
    let fold: TreeSectionDerivation.PieceFold

    var body: some View {
        // Built once for the fold rather than once per row: the bundle is a
        // pile of closures over the same store, and nothing in it varies by
        // item (`ResearchTreeNode` passes the row in at call time).
        let actions = actions
        ForEach(fold.items) { item in
            ResearchTreeNode(
                item: item,
                renamingItemId: $state.renamingItemId,
                findParentId: { findParentId(of: $0) },
                actions: actions,
                // A folded row is a subject of the window exactly like a row in
                // the Research section below — same case, same id. Nothing here
                // knows it is inside a fold.
                tagFor: { BinderSubject.research($0.id) },
                expandsGroups: fold.semantic == .contained)
        }
    }

    /// The tree's own action bundle, with **one verb re-routed**.
    ///
    /// `BinderTreeVerbs` is the bundle, and this asks it for one rather than
    /// building a second — three copies of the store wiring is precisely what
    /// `BinderTreeSections` warns about. It asks the *verbs* and not the
    /// sections view, deliberately: constructing the view to reach its bundle
    /// put a `BinderTreeSections(` call in this file, which is the token
    /// `TripwireGrepTests`' pairing census reads as a host mounting section
    /// rows without their presentations. The census caught it, and the fix was
    /// to make the verbs a value.
    ///
    /// **Why `newNote` is the exception.** Every verb on a fold row that names a
    /// parent group is already right: the piece's groups are in
    /// `manifest.research` like any other, so `New Note` inside one, and the
    /// group-only verbs (`New Group`, `Add File…`, `Add Link…`, which
    /// `ResearchTreeNode` offers on group rows only), all pass a real parent id
    /// and land in it. The one hole is a fold row at the piece's root, whose
    /// parent id is `nil` — and `nil` means the SHARED root. A writer
    /// right-clicking a note inside a chapter's fold and asking for another one
    /// would have got a note in shared research, unlinked from the chapter they
    /// asked from. So the nil case routes through `ResearchScope` instead, which
    /// is the seam that already knows what `.document(id)` means for each
    /// project type: a note in the piece's folder for a collection, a shared
    /// note plus a link for a novel chapter. Both land in this fold, which is
    /// what the writer asked for. The rule itself is never restated here.
    var actions: ResearchTreeActions {
        let base = verbs.bundle
        var actions = base
        actions.newNote = { [verbs, documentId, store] parentId in
            guard parentId == nil else { return base.newNote(parentId) }
            verbs.create {
                try await store.createResearchNote(scope: .document(documentId))
            }
        }
        return actions
    }

    private var verbs: BinderTreeVerbs {
        BinderTreeVerbs(store: store, state: state, selectedSubject: $selectedSubject)
    }

    private func findParentId(of childId: String) -> String? {
        verbs.findParentId(of: childId)
    }
}
