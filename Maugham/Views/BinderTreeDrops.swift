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
        let target = TreeDropIntent.Target.pieceRow(documentId)
        let intent = classify(draggedId, on: target)
        if case .structureReorder = intent {
            // The manuscript never batches: `actingIds` answers with the row
            // alone for anything but a homogeneous research selection, and this
            // arm is a structure id by construction.
            structureReorder()
            return true
        }
        return apply(intent,
                     movingIds: batchIds(for: intent, draggedId: draggedId,
                                         on: target),
                     payload: draggedId, site: "piece row \(documentId)")
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
            return reorder(
                draggedId: draggedId,
                movingIds: batchIds(for: intent, draggedId: draggedId,
                                    on: treeTarget),
                position: position, target: target)
        }
        // A cross-scope drop still lands WHERE it was aimed: the index is
        // computed against the destination the classifier chose, so an item
        // dragged in from another scope doesn't jump to the end of the list.
        let moving = batchIds(for: intent, draggedId: draggedId, on: treeTarget)
        return apply(intent, movingIds: moving, payload: draggedId,
                     site: "research row \(target.id)",
                     atIndex: insertionIndex(movingIds: moving, position: position,
                                             target: target))
    }

    /// A drop on the shared Research section — its header, or the placeholder
    /// row an empty section shows. (A `Section` itself has no live drop region;
    /// `CollectionResearchPane` measured that and this tree inherits it.)
    func routeSharedSectionDrop(draggedId: String) -> Bool {
        let intent = classify(draggedId, on: .sharedSection)
        return apply(intent,
                     movingIds: batchIds(for: intent, draggedId: draggedId,
                                         on: .sharedSection),
                     payload: draggedId, site: "the Research section")
    }

    // MARK: - A drop from outside the app (stage-2b Task 4)

    /// **A Finder file or a browser bitmap, dropped anywhere on the tree.**
    ///
    /// The stage-2a tree refused these outright, because a file has to land in
    /// a SCOPE and the tree had no rule for which one. `TreeDropIntent`'s
    /// external classifier is that rule, and this performs it: one entry point
    /// for every target, so the four surfaces that mount an external drop
    /// cannot come to disagree about what a piece row means.
    ///
    /// **`[NSItemProvider]` rather than `[URL]`, and that is not incidental.** A
    /// browser image drag carries a rendered bitmap and no file URL at all, so
    /// `.dropDestination(for: URL.self)` rejects it silently — nothing logged,
    /// nothing red, the writer's picture simply gone (the canvas's 1C-d
    /// lesson). `DropClassification` is the one classifier that takes both
    /// kinds, and it is what turns a bitmap into an importable temp file.
    ///
    /// Returns whether the drop was ACCEPTED, which is a property of the
    /// TARGET: whether the providers then yield anything importable is only
    /// knowable asynchronously, and the panes this replaces answered the same
    /// way. A refusal is loud in the log and bounces the drag.
    func routeExternalDrop(
        providers: [NSItemProvider], position: DropIntent.Position,
        target: TreeDropIntent.Target
    ) -> Bool {
        let intent = TreeDropIntent.classifyExternal(
            target: target, position: position,
            structure: store.manifest.structure,
            research: store.manifest.research,
            projectType: store.manifest.type)
        switch intent {
        case .refuse(let reason):
            return refuseDrop(site(of: target), payload: nil, reason: reason)
        case .importFiles(let destination):
            perform {
                let urls = await DropClassification.fileURLs(from: providers)
                guard !urls.isEmpty else { return }
                try await importFiles(urls, to: destination)
            }
            return true
        }
    }

    /// Imports `urls` where the classifier said, through the store verb that
    /// destination names.
    ///
    /// Not `private`: this is where the files actually land, and a test can
    /// hand it real URLs without a drag session — which is the only way to
    /// assert the *link* half of `.sharedAndLink` separately from the import.
    func importFiles(
        _ urls: [URL], to destination: TreeDropIntent.ExternalDestination
    ) async throws {
        switch destination {
        case .sharedGroup(let parentId):
            _ = try await store.importResearchFiles(urls, toParentId: parentId)
        case .piece(let pieceId):
            _ = try await store.importPieceResearchFiles(
                pieceId: pieceId, urls: urls)
        case .sharedAndLink(let documentId):
            // **One act.** A novel chapter's research is a link, so an import
            // that stopped here would leave the file in the shared section the
            // writer did not aim at, with the chapter's fold unchanged.
            let imported = try await store.importResearchFiles(
                urls, toParentId: nil)
            for item in imported {
                try await store.linkResearch(
                    researchId: item.id, toDocumentId: documentId)
            }
        }
    }

    /// What the log calls a target, for a refusal that has no payload id to
    /// name.
    private func site(of target: TreeDropIntent.Target) -> String {
        switch target {
        case .pieceRow(let id): return "piece row \(id)"
        case .sharedSection: return "the Research section"
        case .researchRow(let id): return "research row \(id)"
        case .foldRow(let rowId, let documentId):
            return "row \(rowId) in \(documentId)'s fold"
        }
    }

    // MARK: - What a drag carries

    /// **The rows a drag carries** (stage-2b Task 3): the tree's whole selection
    /// when the dragged row is inside one, filtered to those rows whose OWN
    /// meaning on this target is the anchor's.
    ///
    /// The filter is the whole design. `actingIds` is standard Mac behaviour —
    /// drag a row inside the selection and the selection comes with it — but a
    /// batch is not homogeneous just because the writer selected it: dragging
    /// three notes onto a chapter where one is already linked, or two notes into
    /// a fold one of them already lives in, has a different answer per row.
    /// Classifying each row on the same target and keeping the ones that agree
    /// means the drop does to every row exactly what that row's own
    /// classification says, and a row with nothing to do quietly does nothing —
    /// rather than the whole batch bouncing, or a `.alreadyThere` row being
    /// dragged along into a move it was never classified for.
    ///
    /// `.rescope` compares DESTINATIONS rather than ids, since each row
    /// classifies with its own id in the payload; the destination is what the
    /// batch mover takes, and it is validate-all-first.
    private func batchIds(for intent: TreeDropIntent.Intent, draggedId: String,
                          on target: TreeDropIntent.Target) -> [String] {
        let acting = actingIds(forRow: draggedId)
        guard acting.count > 1 else { return acting }
        return acting.filter { id in
            id == draggedId || agrees(classify(id, on: target), with: intent)
        }
    }

    private func agrees(_ lhs: TreeDropIntent.Intent,
                        with rhs: TreeDropIntent.Intent) -> Bool {
        switch (lhs, rhs) {
        case (.rescope(_, let a), .rescope(_, let b)): return a == b
        case (.link(_, let a), .link(_, let b)): return a == b
        case (.unlink(_, let a), .unlink(_, let b)): return a == b
        case (.researchReorder, .researchReorder): return true
        // Everything else disagrees — including a row whose own answer is a
        // refusal or `.alreadyThere`, which is the case this filter exists for.
        default: return false
        }
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

    /// Performs `intent` for every row the drag carries (stage-2b Task 3). The
    /// batch is `batchIds`', and for a one-row drag it is the row itself, so
    /// every arm below reads the same whether the writer dragged one note or
    /// five. `.rescope` goes through the plural mover in ONE call — it validates
    /// the whole batch before it moves anything, which a loop cannot; link and
    /// unlink have no plural verb, so they are a sequential loop inside one
    /// task, and a throw stops it and surfaces in the tree's alert.
    private func apply(
        _ intent: TreeDropIntent.Intent, movingIds batch: [String],
        payload: String, site: String, atIndex: Int? = nil
    ) -> Bool {
        switch intent {
        case .rescope(let ids, let target):
            perform { try await store.moveResearchItems(
                ids: batch.isEmpty ? ids : batch, to: target, atIndex: atIndex) }
            return true
        case .link(let researchId, let documentId):
            let batch = batch.isEmpty ? [researchId] : batch
            perform {
                for id in batch {
                    try await store.linkResearch(
                        researchId: id, toDocumentId: documentId)
                }
            }
            return true
        case .unlink(let researchId, let documentId):
            let batch = batch.isEmpty ? [researchId] : batch
            perform {
                for id in batch {
                    try await store.unlinkResearch(
                        researchId: id, fromDocumentId: documentId)
                }
            }
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
    ///
    /// **A batch reorders through the plural mover, and its destination is
    /// named rather than implied** (stage-2b Task 3). `moveResearchItem` takes a
    /// parent id, where `nil` means the shared root — which is why the single
    /// case above uses it and the batch cannot: a piece-root item's parent id is
    /// also `nil`, and handing that to the batch mover as `.sharedRoot` would
    /// turn a reorder inside a Collection piece into a move of the writer's
    /// files out of it. `TreeDropIntent.container(ofRow:)` is the rule that
    /// already answers *"what does beside this row mean"* — `.group`, `.piece`
    /// or `.sharedRoot` — and it is called here rather than restated.
    private func reorder(
        draggedId: String, movingIds: [String],
        position: DropIntent.Position, target: ResearchItem
    ) -> Bool {
        let batched = movingIds.count > 1
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
                targetId: target.id, position: position, movingIds: movingIds,
                siblings: siblings(of: toParentId)) else {
                // The target is inside the batch (which includes the dragged row
                // itself) or is not among the siblings it should be — nothing to
                // anchor to.
                return refuseDrop("research row \(target.id)",
                                  payload: draggedId, reason: .sameRow)
            }
            destIndex = index
        }
        guard batched else {
            perform { try await store.moveResearchItem(
                id: draggedId, toParentId: toParentId, atIndex: destIndex) }
            return true
        }
        let destination: ResearchMoveTarget = position == .middle
            && target.type == .group
            ? .group(target.id)
            : TreeDropIntent.container(ofRow: target.id,
                                       structure: store.manifest.structure,
                                       research: store.manifest.research)
        perform { try await store.moveResearchItems(
            ids: movingIds, to: destination, atIndex: destIndex) }
        return true
    }

    /// Where a cross-scope drop lands within its new container: beside the row
    /// it was aimed at. `nil` appends, which is what the batch mover does with
    /// a `nil` index. The moving ids are the drag's whole batch, because the
    /// mover removes them all before it inserts and an index taken against the
    /// pre-removal list drifts by however many of them preceded the target.
    private func insertionIndex(
        movingIds: [String], position: DropIntent.Position, target: ResearchItem
    ) -> Int? {
        ResearchSelectionSync.postRemovalInsertionIndex(
            targetId: target.id, position: position, movingIds: movingIds,
            siblings: siblings(of: findParentId(of: target.id)))
    }

    private func siblings(of parentId: String?) -> [ResearchItem] {
        guard let parentId,
              let parent = TreeWalk.find(id: parentId, in: store.manifest.research)
        else { return store.manifest.research }
        return parent.children ?? []
    }
}
