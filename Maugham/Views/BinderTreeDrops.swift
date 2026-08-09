import SwiftUI
import MaughamCore

/// **Performing what `TreeDropIntent` decided** (shell-finish stage-2a Task 7).
///
/// The classifier says what a drop MEANS; this says what the store is asked to
/// do about it, and it is the only place in the tree that asks. The split is
/// what makes the routing testable at all — a real drag session is not
/// synthesisable headless, so the decision lives in a pure function with a
/// whole grid of tests behind it (`TreeDropIntentTests`) and the performer
/// below is a switch with no judgement of its own.
///
/// **Nothing here computes an index by hand.** Insertion goes through
/// `ResearchSelectionSync.postRemovalInsertionIndex` — the batch movers remove
/// before they insert, so an index taken against the pre-removal list drifts,
/// and three shipped off-by-ones say so. The reorder itself is
/// `ProjectStore.moveResearchItem`, the same mover `ResearchView` has always
/// used; the scope moves are the typed batch mover
/// `ProjectStore.moveResearchItems`, whose own refusals (a role-bearing item
/// asked to change scope, a group into its own descendant) arrive as thrown
/// errors and surface in the tree's alert. **They are never swallowed**: a
/// refusal the writer cannot see is the silent no-op the publishing-namespace
/// finding is about.
///
/// **Every one of these returns whether the drop was ACCEPTED**, and the rows
/// return exactly that (`ResearchRow`, `BinderRow`, `PieceRow`). A refused drop
/// bounces back to where the writer took it from; accepting one the tree cannot
/// route animates it home and drops it on the floor, which is precisely what
/// shipped in Task 4's first round.
extension BinderTreeVerbs {

    // MARK: - The three targets

    /// A drop on a manuscript row — a chapter, a Collection piece, a structure
    /// group.
    ///
    /// **The manuscript reorder is not this file's**: a structure id dropped
    /// here is the binder's own drag, and the host's existing handler (which
    /// goes through `DropIntent.classify` and `moveStructureItem`) runs
    /// untouched. Task 7 only adds the case where what was dragged is research.
    func routePieceRowDrop(
        draggedId: String, documentId: String, structureReorder: () -> Void
    ) -> Bool {
        let intent = classify(draggedId, on: .pieceRow(documentId))
        if case .structureReorder = intent {
            structureReorder()
            return true
        }
        return apply(intent, payload: draggedId, on: "piece row \(documentId)")
    }

    /// A drop on a research row: in the shared Research section
    /// (`inFoldOf: nil`) or inside a piece's fold, which is the same row type
    /// with a document behind it.
    func routeResearchRowDrop(
        draggedId: String, position: DropIntent.Position,
        target: ResearchItem, inFoldOf documentId: String?
    ) -> Bool {
        let treeTarget: TreeDropIntent.Target = documentId.map {
            .foldRow(rowId: target.id, documentId: $0)
        } ?? .researchRow(target.id)
        let intent = classify(draggedId, on: treeTarget)
        if case .researchReorder = intent {
            return reorder(draggedId: draggedId, position: position, target: target)
        }
        // A cross-scope drop still lands WHERE it was aimed: the index is
        // computed against the destination the classifier chose, so an item
        // dragged in from another scope doesn't jump to the end of the list.
        return apply(intent, payload: draggedId, on: "research row \(target.id)",
                     atIndex: insertionIndex(draggedId: draggedId,
                                             position: position, target: target))
    }

    /// A drop on the shared Research section — its header, or the placeholder
    /// row an empty section shows. (A `Section` itself has no live drop region;
    /// `CollectionResearchPane` measured that and this tree inherits it.)
    func routeSharedSectionDrop(draggedId: String) -> Bool {
        apply(classify(draggedId, on: .sharedSection),
              payload: draggedId, on: "the Research section")
    }

    // MARK: - Deciding, then doing

    private func classify(
        _ payloadId: String, on target: TreeDropIntent.Target
    ) -> TreeDropIntent.Intent {
        TreeDropIntent.classify(
            payloadId: payloadId, target: target,
            structure: store.manifest.structure,
            research: store.manifest.research,
            projectType: store.manifest.type)
    }

    private func apply(
        _ intent: TreeDropIntent.Intent, payload: String, on site: String,
        atIndex: Int? = nil
    ) -> Bool {
        switch intent {
        case .rescope(let ids, let target):
            perform { try await store.moveResearchItems(
                ids: ids, to: target, atIndex: atIndex) }
            return true
        case .link(let researchId, let documentId):
            perform { try await store.linkResearch(
                researchId: researchId, toDocumentId: documentId) }
            return true
        case .unlink(let researchId, let documentId):
            perform { try await store.unlinkResearch(
                researchId: researchId, fromDocumentId: documentId) }
            return true
        case .refuse(let reason):
            return refuseDrop(site, payload: payload, reason: reason)
        case .researchReorder, .structureReorder:
            // Both belong to a caller that knows the target row and the drop's
            // vertical position, and both callers handle them above. Reaching
            // here is a wiring mistake — and it must not look like an accepted
            // drop, or the mistake ships as a drag that vanishes.
            return refuseDrop(
                "\(site) — \(intent) reached the generic performer", payload: payload)
        }
    }

    /// The ordinary same-scope reorder. Not reinvented: the index is
    /// `ResearchSelectionSync`'s and the move is `ProjectStore.moveResearchItem`,
    /// which reparents within a scope and never moves a file between scopes —
    /// the batch mover would, and a piece-root item whose parent id is `nil`
    /// would read as "shared root" to it.
    private func reorder(
        draggedId: String, position: DropIntent.Position, target: ResearchItem
    ) -> Bool {
        let toParentId: String?
        let destIndex: Int
        if position == .middle, target.type == .group {
            // Into the group, at its head — the target is the new parent here,
            // not a sibling, so there is no insertion index to compute.
            toParentId = target.id
            destIndex = 0
        } else {
            toParentId = findParentId(of: target.id)
            guard let index = ResearchSelectionSync.postRemovalInsertionIndex(
                targetId: target.id, position: position, movingIds: [draggedId],
                siblings: siblings(of: toParentId)) else {
                // The target is the dragged row itself or is not among the
                // siblings it should be — nothing to anchor to.
                return refuseDrop("research row \(target.id)",
                                  payload: draggedId, reason: .sameRow)
            }
            destIndex = index
        }
        perform { try await store.moveResearchItem(
            id: draggedId, toParentId: toParentId, atIndex: destIndex) }
        return true
    }

    /// Where a cross-scope drop lands within its new container: beside the row
    /// it was aimed at. `nil` appends, which is what the batch mover does with
    /// a `nil` index.
    private func insertionIndex(
        draggedId: String, position: DropIntent.Position, target: ResearchItem
    ) -> Int? {
        ResearchSelectionSync.postRemovalInsertionIndex(
            targetId: target.id, position: position, movingIds: [draggedId],
            siblings: siblings(of: findParentId(of: target.id)))
    }

    private func siblings(of parentId: String?) -> [ResearchItem] {
        guard let parentId,
              let parent = TreeWalk.find(id: parentId, in: store.manifest.research)
        else { return store.manifest.research }
        return parent.children ?? []
    }
}
