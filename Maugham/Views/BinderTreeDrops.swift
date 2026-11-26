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
            let moving = batchIds(for: intent, draggedId: draggedId, on: treeTarget)
            state.researchDragSource = nil
            return reorder(draggedId: draggedId, movingIds: moving,
                           position: position, target: target)
        }
        // A cross-scope drop still lands WHERE it was aimed: the index is
        // computed against the destination the classifier chose, so an item
        // dragged in from another scope doesn't jump to the end of the list.
        let moving = batchIds(for: intent, draggedId: draggedId, on: treeTarget)
        return apply(intent, movingIds: moving, payload: draggedId,
                     site: "research row \(target.id)",
                     landing: insertionIndex(movingIds: moving, position: position,
                                             target: target) == nil
                        ? .end : .beside(rowId: target.id, position: position))
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

    /// **A drop on the Figures section** — its header or a figure's row
    /// (report plan 8b Task 5). A Research table, picture or PDF is *Use in
    /// Document*; a figure is refused, since numbers follow the text.
    func routeFiguresDrop(draggedId: String, target: TreeDropIntent.Target) -> Bool {
        apply(classify(draggedId, on: target), movingIds: [draggedId],
              payload: draggedId, site: site(of: target))
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
        switch externalIntent(on: target, position: position) {
        case .refuse(let reason):
            return refuseDrop(site(of: target), payload: nil, reason: reason)
        case .importFiles(let destination):
            // A file a chapter takes lands in its fold: open it, so it never
            // seems to vanish (shell p5 Task 4a).
            if case .sharedAndLink(let documentId) = destination {
                state.expandedPieceFolds.insert(documentId)
            }
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
            try await relink(imported.map(\.id), from: [], to: documentId)
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
        case .figuresSection: return "the Figures section"
        case .figureRow(let id): return "figure row \(id)"
        }
    }

    // MARK: - What a target shows while a drag is over it (shell p4 Task 10)

    /// **The answers a target shows for the drag in flight**, at each of the
    /// drop's positions — the drop's own rules, read off the drag pasteboard
    /// as the header's drop reads it (`BinderTreeSections.draggedId`). A drag
    /// of files or a picture asks the external rule; any other drag the
    /// internal one, with its id. `refusesStructure`: a host's posture refusal
    /// of a structure row it may not move (the hosts' `onDrop` ask the same).
    /// `halves`: a Collection piece row, whose drop reads halves.
    func dropAnswers(on target: TreeDropIntent.Target,
                     pasteboard: NSPasteboard = NSPasteboard(name: .drag),
                     refusesStructure: (String) -> Bool = { _ in false },
                     halves: Bool = false) -> TreeDropAnswers {
        let types = (pasteboard.types ?? []).map(\.rawValue)
        switch ProviderDropRoute.route(typeIdentifiers: types) {
        case .external:
            return TreeDropAnswers { externalFeedback(on: target, position: $0) }
        case .refuse:
            return .none
        case .internalPayload:
            guard let id = BinderTreeSections.draggedId(on: pasteboard) else { return .none }
            return answers(draggedId: id, on: target, refusesStructure: refusesStructure,
                           halves: halves)
        }
    }

    /// The internal half, by id: `classify`, then — where the landing depends
    /// on the drop's position — the very rule the drop performs at that
    /// position (`DropIntent.classify` for a manuscript reorder,
    /// `CollectionPiecesPane.landsBelow` for a piece, `reorderLanding` for a
    /// research reorder, `insertionIndex` for a move beside a row).
    func answers(draggedId: String, on target: TreeDropIntent.Target,
                 refusesStructure: (String) -> Bool = { _ in false },
                 halves: Bool = false) -> TreeDropAnswers {
        let structure = store.manifest.structure
        if TreeWalk.find(id: draggedId, in: structure) != nil, refusesStructure(draggedId) {
            return .none
        }
        let intent = classify(draggedId, on: target)
        switch intent {
        case .structureReorder:
            guard case .pieceRow(let rowId) = target,
                  let row = TreeWalk.find(id: rowId, in: structure) else { return .none }
            if halves {
                return TreeDropAnswers { CollectionPiecesPane.landsBelow($0) ? .below : .above }
            }
            return TreeDropAnswers { position in
                switch DropIntent.classify(position: position, target: row) {
                case .insertAbove: return .above
                case .insertBelow: return .below
                case .insertChild: return .into
                }
            }
        case .researchReorder:
            guard let row = researchRow(of: target) else { return .none }
            let moving = batchIds(for: intent, draggedId: draggedId, on: target)
            return TreeDropAnswers { reorderLanding(position: $0, target: row, movingIds: moving) }
        case .rescope:
            let flat = TreeDropFeedback.of(intent, on: target)
            guard flat == .beside, let row = researchRow(of: target) else {
                return TreeDropAnswers(same: flat)
            }
            // Beside a leaf: the drop names an index from its position.
            let moving = batchIds(for: intent, draggedId: draggedId, on: target)
            return TreeDropAnswers { position in
                insertionIndex(movingIds: moving, position: position, target: row) == nil
                    ? .beside : (position == .top ? .above : .below)
            }
        default:
            return TreeDropAnswers(same: TreeDropFeedback.of(intent, on: target))
        }
    }

    /// The external half at one position: `routeExternalDrop`'s own
    /// classification.
    func externalFeedback(on target: TreeDropIntent.Target,
                          position: DropIntent.Position) -> TreeDropFeedback {
        TreeDropFeedback.of(externalIntent(on: target, position: position), on: target)
    }

    /// **A Finder drop's meaning, its piece's posture asked** (fix round 1,
    /// I4): a file a chapter would LINK is a link edit — refused, and named,
    /// where this Mac may not change that chapter's links
    /// (`mayEditResearchLinks`, tripwire 51). A file filed into a Collection
    /// piece's own folder is creation, asked exactly what that fold's New
    /// Note asks — nothing of the link door (fix round 2, NB5).
    func externalIntent(on target: TreeDropIntent.Target,
                        position: DropIntent.Position) -> TreeDropIntent.ExternalIntent {
        let intent = TreeDropIntent.classifyExternal(
            target: target, position: position,
            structure: store.manifest.structure,
            research: store.manifest.research,
            projectType: store.manifest.type)
        switch intent {
        case .importFiles(.sharedAndLink(let piece)):
            return mayEditResearchLinks(of: piece) ? intent : .refuse(.linksNotPermitted)
        default:
            return intent
        }
    }

    /// **Where a research reorder lands at `position`** — the rule `reorder`
    /// performs: a group's middle takes it in; anywhere else beside the row,
    /// where an index exists for the batch the drag carries
    /// (`postRemovalInsertionIndex`), else refused. Pure over the manifest.
    func reorderLanding(position: DropIntent.Position, target: ResearchItem,
                        movingIds: [String]) -> TreeDropFeedback {
        if position == .middle, target.type == .group { return .into }
        guard ResearchSelectionSync.postRemovalInsertionIndex(
            targetId: target.id, position: position, movingIds: movingIds,
            siblings: siblings(of: findParentId(of: target.id))) != nil else { return .none }
        return position == .top ? .above : .below
    }

    private func researchRow(of target: TreeDropIntent.Target) -> ResearchItem? {
        switch target {
        case .researchRow(let id), .foldRow(let id, _):
            return TreeWalk.find(id: id, in: store.manifest.research)
        case .pieceRow, .sharedSection, .figuresSection, .figureRow:
            return nil
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
        case (.moveLink(_, let a, let c), .moveLink(_, let b, let d)): return a == b && c == d
        case (.leaveGroup(_, let a), .leaveGroup(_, let b)): return a == b
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
        let intent = permitted(TreeDropIntent.classify(
            payloadId: payloadId, target: target,
            sourcePiece: state.dragSource(of: payloadId),
            structure: store.manifest.structure,
            research: store.manifest.research,
            figures: store.manifest.figures ?? [],
            projectType: store.manifest.type,
            // The window's homes, derived once per manifest — never once per
            // row of a batch, nor per hover (M3).
            homes: state.researchHomes(in: store.manifest)))
        // **Read-through holds what a chapter in it holds** (closing round
        // A, branch I2): such a row is not moved out, reordered or unlinked
        // by a drag; giving it to another chapter as well is no change to it.
        switch intent {
        case .rescope, .unlink, .moveLink, .leaveGroup, .researchReorder:
            return readThroughRefusal([payloadId]) == nil ? intent : .refuse(.readThrough)
        default:
            return intent
        }
    }

    /// **A link edit asks what linking asks** (shell p5 Task 4a): the piece's
    /// structure door (`TreeStructureVerbs.linkResearch`, the posture's one
    /// door — what "Link Research…" asks). Refused, it names why, and its hover
    /// shows nothing.
    func permitted(_ intent: TreeDropIntent.Intent) -> TreeDropIntent.Intent {
        switch intent {
        case .link(_, let piece), .unlink(_, let piece):
            return mayEditResearchLinks(of: piece) ? intent : .refuse(.linksNotPermitted)
        case .moveLink(_, let from, let to):
            return mayEditResearchLinks(of: from) && mayEditResearchLinks(of: to)
                ? intent : .refuse(.linksNotPermitted)
        case .leaveGroup(let id, let to):
            let leaving = state.researchHomes(in: store.manifest).chaptersThroughGroup(of: id)
            return (leaving + [to]).allSatisfy { mayEditResearchLinks(of: $0) }
                ? intent : .refuse(.linksNotPermitted)
        default:
            return intent
        }
    }

    /// Where a link drop's rows land, in sight (`showLanding`).
    private func land(_ ids: [String], inFoldOf piece: String?) {
        state.showLanding(of: ids, inFoldOf: piece, structure: store.manifest.structure,
                          research: store.manifest.research)
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
        payload: String, site: String, landing: HeldResearchAct.Landing = .end
    ) -> Bool {
        // The drag is over: its record goes (M9).
        state.researchDragSource = nil
        switch intent {
        case .rescope(let ids, let target):
            return requestMove(batch.isEmpty ? ids : batch, to: target, landing: landing)
        case .link(let researchId, let documentId):
            let batch = batch.isEmpty ? [researchId] : batch
            land(batch, inFoldOf: documentId)
            perform { try await relink(batch, from: [], to: documentId) }
            return true
        case .unlink(let researchId, let documentId):
            let batch = batch.isEmpty ? [researchId] : batch
            land(batch, inFoldOf: nil)
            perform { try await relink(batch, from: [documentId], to: nil) }
            return true
        case .moveLink(let researchId, let from, let to):
            let batch = batch.isEmpty ? [researchId] : batch
            land(batch, inFoldOf: to)
            perform { try await relink(batch, from: [from], to: to) }
            return true
        case .leaveGroup(let researchId, let documentId):
            // Out of the chapter's group to the Research root, then linked:
            // the second chapter's (closing round A).
            let batch = batch.isEmpty ? [researchId] : batch
            land(batch, inFoldOf: documentId)
            perform {
                try await Self.performMove(batch, to: .sharedRoot, landing: .end, lifts: [],
                                           afterLift: "", store: store)
                try await relink(batch, from: [], to: documentId)
            }
            return true
        case .useInDocument(let researchId):
            return FigureSectionVerbs(store: store, state: state).dropToUse(researchId: researchId) != nil
        case .sendFigureToResearch(let figureId, let scope, let group):
            // Asked first (D8-2): the send is the confirmation's.
            return FigureSectionVerbs(store: store, state: state)
                .dropToSend(figureId: figureId, scope: scope, group: group)
        case .refuse(let reason):
            // A read-through refusal names the piece, as every surface does.
            if case .readThrough = reason, let refusal = readThroughRefusal([payload]) {
                state.pendingError = refusal
            }
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
    /// `ResearchSelectionSync`'s, and the move is the tree's one research-move
    /// door (`requestMove`, fix round 2), one row or a batch alike.
    ///
    /// **Its destination is named rather than implied** (stage-2b Task 3): a
    /// piece-root item's parent id is `nil`, and handing that to the mover as
    /// `.sharedRoot` would turn a reorder inside a Collection piece into a
    /// move of the writer's files out of it. `TreeDropIntent.container(ofRow:)`
    /// is the rule that already answers *"what does beside this row mean"* —
    /// `.group`, `.piece` or `.sharedRoot` — and it is called here rather than
    /// restated.
    private func reorder(
        draggedId: String, movingIds: [String],
        position: DropIntent.Position, target: ResearchItem
    ) -> Bool {
        // The hover's answer at this position, asked here too, so the two
        // cannot disagree about a refusal (review Minor 3).
        guard reorderLanding(position: position, target: target,
                             movingIds: movingIds).accepts else {
            return refuseDrop("research row \(target.id)", payload: draggedId, reason: .sameRow)
        }
        let landing: HeldResearchAct.Landing
        if position == .middle, target.type == .group {
            // Into the group, at its head — the target is the new parent here.
            landing = .head
        } else {
            guard ResearchSelectionSync.postRemovalInsertionIndex(
                targetId: target.id, position: position, movingIds: movingIds,
                siblings: siblings(of: findParentId(of: target.id))) != nil else {
                // The target is inside the batch (which includes the dragged row
                // itself) or is not among the siblings it should be — nothing to
                // anchor to.
                return refuseDrop("research row \(target.id)",
                                  payload: draggedId, reason: .sameRow)
            }
            // Found again where the move is made, after any lift (round 3, c).
            landing = .beside(rowId: target.id, position: position)
        }
        // One door for every research move (fix round 2, NB2): a group
        // dragged over a piece's note asks as the menu's Move does. The
        // destination is named, never implied: `container(ofRow:)` is the
        // rule for what beside this row means, so a piece-root row's nil
        // parent never reads as the shared root.
        let destination: ResearchMoveTarget = position == .middle
            && target.type == .group
            ? .group(target.id)
            : TreeDropIntent.container(ofRow: target.id,
                                       structure: store.manifest.structure,
                                       research: store.manifest.research)
        return requestMove(movingIds, to: destination, landing: landing)
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
