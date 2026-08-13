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
                //
                // **In a novel that is the SAME tag twice in one `List`**, on
                // this row and on its twin in the shared Research section, and
                // that is intended: both rows are the one subject, so selecting
                // either highlights both and the writer sees where the note
                // they picked also lives. What the duplicate must NOT be
                // allowed to duplicate is a control — see `offersRename` below
                // and `ResearchTreeNode.offersRename` for the rename field that
                // did.
                tagFor: { BinderSubject.research($0.id) },
                expandsGroups: fold.semantic == .contained,
                // A linked fold is a view of the chapter's links; its rows are
                // drawn a second time in the shared section, and one
                // `renamingItemId` matching two rows mounts two rename fields
                // (finding I2). A contained fold's rows are drawn once and keep
                // the verb.
                offersRename: fold.semantic == .contained,
                // **The fold's own groups share the tree's set of open ids**
                // (stage-3b Task 7). `ResearchTreeNode`'s `nil` default —
                // SwiftUI holds the flag — was right while nothing outside a
                // click ever opened one of these; the reveal is that
                // something, and a group inside a piece's fold is exactly
                // where a piece-scoped note it names can live. The ids are
                // research ids either way, distinct across the manifest by
                // construction, so one set cannot confuse a fold's group with
                // a shared one.
                expandedGroups: $state.expandedResearchGroups)
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
        // **The second re-routed verb, and the same reason** (Task 7): a drop
        // on a row in this fold is aimed at THIS document. Without the
        // document, `TreeDropIntent` would read the row as an ordinary shared
        // research row and answer "reorder" — so a note dropped into chapter
        // three's fold would silently change the order of shared research and
        // never reach chapter three. The fold is a near-miss of the piece row
        // above it and means the same thing.
        actions.internalDrop = { [verbs, documentId] draggedId, position, target in
            verbs.routeResearchRowDrop(draggedId: draggedId, position: position,
                                       target: target, inFoldOf: documentId)
        }
        // **The third re-routed verb, and it fails the same silent way**
        // (stage-2b Task 4): a Finder file dropped in chapter three's fold is
        // chapter three's. Without the document, the classifier reads the row
        // as an ordinary shared research row and the file lands in shared
        // research, unlinked — no error, nothing missing on screen, and the
        // chapter the writer aimed at simply never gets it.
        actions.externalDrop = { [verbs, documentId] providers, position, target in
            verbs.routeExternalDrop(
                providers: providers, position: position,
                target: .foldRow(rowId: target.id, documentId: documentId))
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
