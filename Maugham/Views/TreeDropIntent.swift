import Foundation
import MaughamCore

/// **What a drag onto the binder tree means** (shell-finish stage-2a Task 7,
/// spec §3).
///
/// The milestone gives every persona ONE left column, so the tree holds
/// manuscript rows, a shared Research section and — since Task 6 — a research
/// fold under each piece, all in one `List`. That makes the drag the writer's
/// verb for scope: a note dropped on a chapter belongs to that chapter, a note
/// dragged out to the Research section belongs to the project again, and in a
/// Collection the same two gestures move the FILE between `research/` and
/// `pieces/<slug>/research/`.
///
/// **One pure classifier, and nothing downstream decides anything.**
/// `BinderTreeVerbs` performs what this returns and computes insertion
/// indices; the hosts hand it a target and a payload. The reason the decision
/// lives in a pure function is that a real drag session is not synthesisable
/// headless — if the routing were spread across four view closures, no test in
/// this repo could see it at all. Here the whole grid (every target × a
/// research id, a structure id and an id belonging to neither × every project
/// type) is a table in `TreeDropIntentTests`.
///
/// **Routing is by LOOKUP, never by the shape of an id.** A payload id is
/// found in `research`, or in `structure`, or in neither — and "neither" is a
/// loud refusal rather than a no-op, because the tree receives drags from the
/// canvas, from other windows and from stale sessions, and an id it cannot
/// place must bounce (the publishing-namespace finding: fail loudly on the
/// silent no-op). `CanvasDrop` reached the same shape for the same reason.
/// The falsifier for this claim is
/// `TreeDropIntentTests.test_theGridCanTellALookupApartFromAGuessAtTheIdsShape`.
///
/// **No rule here is this file's own.** Which scope a document owns is
/// `ProjectStore.researchRouting(for:projectType:)`; which piece a research
/// path lives under is `ProjectStore.researchScopePieceId(ofPath:structure:)`.
/// Both are the pure cores the store already exposes, called and never
/// restated — `TreeSectionDerivation` (Task 3) is built the same way.
enum TreeDropIntent {

    /// Where a drop landed. Every drop target the tree mounts is one of these,
    /// and the target is what the writer aimed at — never what they dragged.
    enum Target: Equatable {
        /// A manuscript row: a chapter, a Collection piece, a structure group.
        case pieceRow(String)
        /// The shared Research section — its header, or the placeholder row an
        /// empty section shows. (A `Section` itself has no live drop region;
        /// `CollectionResearchPane` measured that.)
        case sharedSection
        /// A research row in the shared Research section.
        case researchRow(String)
        /// A research row inside a piece's fold. **Its document is the point**:
        /// the fold is a near-miss of the piece row above it and means the same
        /// thing, so a note dropped inside chapter 3's fold joins chapter 3
        /// rather than reordering shared research behind the writer's back.
        case foldRow(rowId: String, documentId: String)
    }

    /// Why a drop was refused. Carried so the refusal can say what it was —
    /// a bounce with a silent log is how the tree's stubs shipped, and this is
    /// the channel that replaces it.
    enum Reason: Equatable {
        /// The payload names nothing in this project — a canvas node, another
        /// window's row, a stale drag.
        case unknownId
        /// A manuscript row dropped on research: a research row is not a
        /// position in the manuscript, so there is no reorder for it to be.
        case structureOntoResearch
        /// Dropped on the row it came from.
        case sameRow
        /// The project keeps all research shared (short story, screenplay), so
        /// there is no scope for the drop to change.
        case sharedOnly
        /// A structure group, a referenced Collection piece, an unknown project
        /// type — `ProjectStore.researchRouting`'s own refusals.
        case notAResearchTarget
        /// The drop would change nothing.
        case alreadyThere
        /// A note already linked to this chapter, dropped on a row inside that
        /// chapter's fold — a reorder of a fold that has no order to set.
        ///
        /// **The refusal is the truth, not a stub.** A `.linked` fold renders
        /// the document's `linkedResearchIds`, and the only reorder the tree can
        /// perform is `ProjectStore.moveResearchItem`, which reorders SHARED
        /// research. So accepting this drop moved rows the writer was not
        /// looking at, in a section they had not aimed at, and left the fold
        /// exactly as it was — an accepted drag that visibly did nothing here
        /// and invisibly did something there. Setting a chapter's link order
        /// needs a `linkedResearchIds` reorder the store does not have; that
        /// API is stage 2b's, and until it exists a bounce is what is honest.
        case linkedFoldHasNoOrder
        /// A novel note linked to more than one chapter, dragged to the shared
        /// section. The payload is a bare id and says nothing about which fold
        /// it came from, so unlinking one (or all) would delete a link the
        /// writer never pointed at.
        case ambiguousSource

        var explanation: String {
            switch self {
            case .unknownId: return "the payload is in neither tree"
            case .structureOntoResearch: return "a manuscript row is not research"
            case .sameRow: return "dropped on itself"
            case .sharedOnly: return "this project keeps all research shared"
            case .notAResearchTarget: return "not a research scope target"
            case .alreadyThere: return "already there — the drop changes nothing"
            case .ambiguousSource: return "linked to more than one document"
            case .linkedFoldHasNoOrder:
                return "a linked chapter's research has no order of its own to set"
            }
        }
    }

    /// What to do about the drop. Performed by `BinderTreeVerbs`.
    enum Intent: Equatable {
        /// Move research between scopes through the typed batch mover
        /// (`ProjectStore.moveResearchItems`) — validate-first, and its own
        /// refusals (a role-bearing item, a cycle) surface in the tree's error
        /// alert rather than here.
        case rescope(ids: [String], to: ResearchMoveTarget)
        case link(researchId: String, toDocumentId: String)
        case unlink(researchId: String, fromDocumentId: String)
        /// Same scope: the ordinary research reorder every research surface has
        /// always had. The performer computes the insertion index; this case
        /// carries none, because the index needs the drop's vertical position
        /// and the position is not part of what a drop MEANS.
        case researchReorder
        /// The binder's own manuscript reorder, untouched by this task — the
        /// host delegates to `DropIntent.classify` / `moveStructureItem`.
        case structureReorder
        case refuse(Reason)
    }

    // MARK: - The classifier

    static func classify(
        payloadId: String,
        target: Target,
        structure: [StructureItem],
        research: [ResearchItem],
        projectType: ProjectType
    ) -> Intent {
        if let dragged = TreeWalk.find(id: payloadId, in: research) {
            return classifyResearch(
                dragged: dragged, target: target, structure: structure,
                research: research, projectType: projectType)
        }
        if TreeWalk.find(id: payloadId, in: structure) != nil {
            switch target {
            case .pieceRow(let targetId):
                guard targetId != payloadId else { return .refuse(.sameRow) }
                guard TreeWalk.find(id: targetId, in: structure) != nil else {
                    return .refuse(.unknownId)
                }
                return .structureReorder
            case .sharedSection, .researchRow, .foldRow:
                return .refuse(.structureOntoResearch)
            }
        }
        return .refuse(.unknownId)
    }

    // MARK: - A research item, by where it was dropped

    private static func classifyResearch(
        dragged: ResearchItem,
        target: Target,
        structure: [StructureItem],
        research: [ResearchItem],
        projectType: ProjectType
    ) -> Intent {
        switch target {
        case .pieceRow(let documentId):
            return into(documentId: documentId, dragged: dragged,
                        structure: structure, research: research,
                        projectType: projectType,
                        whenAlreadyLinked: .refuse(.alreadyThere),
                        whenAlreadyContained: .refuse(.alreadyThere))

        case .foldRow(let rowId, let documentId):
            guard rowId != dragged.id else { return .refuse(.sameRow) }
            // Already this document's — and what that means depends on which
            // KIND of fold the writer is inside, which is why the two arms are
            // separate parameters rather than one (the final review's I1).
            //
            // A CONTAINED fold (a Collection piece) is a real tree in the
            // piece's own `research/`, so the rows have an order and the
            // ordinary reorder sets it. A LINKED fold (a novel chapter) draws
            // `linkedResearchIds`, whose order nothing here can change — see
            // `Reason.linkedFoldHasNoOrder`.
            return into(documentId: documentId, dragged: dragged,
                        structure: structure, research: research,
                        projectType: projectType,
                        whenAlreadyLinked: .refuse(.linkedFoldHasNoOrder),
                        whenAlreadyContained: .researchReorder)

        case .researchRow(let targetId):
            guard targetId != dragged.id else { return .refuse(.sameRow) }
            guard TreeWalk.find(id: targetId, in: research) != nil else {
                return .refuse(.unknownId)
            }
            let from = owningPieceId(of: dragged.id, structure: structure,
                                     research: research)
            let to = owningPieceId(of: targetId, structure: structure,
                                   research: research)
            guard from != to else { return .researchReorder }
            // **A GROUP row is a destination, not a neighbour** (stage 2b final
            // review's I4). The old research pane read middle-on-group as
            // *into that group*, and `classifyExternal` still does one function
            // down — so a Finder file dropped on "World" entered it while a note
            // dragged from a piece landed beside it, in the group's parent, from
            // the same gesture at the same pixel. Two answers to one question.
            //
            // The internal classifier is given no drop POSITION (a row's string
            // destination reports none), so a group target means the group: the
            // one reading that can never file the writer's note somewhere they
            // did not aim.
            if TreeWalk.find(id: targetId, in: research)?.type == .group {
                return .rescope(ids: [dragged.id], to: .group(targetId))
            }
            // Cross-scope, onto a leaf. The row's CONTAINER is where the item
            // lands — its parent group if it has one, else the root of its
            // scope. Dropping beside a row must not put the item somewhere the
            // writer cannot see it, which is what appending to the scope root
            // would do to a drop aimed inside a group.
            return .rescope(ids: [dragged.id],
                            to: container(ofRow: targetId, structure: structure,
                                          research: research))

        case .sharedSection:
            return outOfScope(dragged: dragged, structure: structure,
                              research: research, projectType: projectType)
        }
    }

    /// A research item dropped **onto** a document — the piece row, or a row in
    /// its fold. What that means is the document's own research routing, asked
    /// rather than restated.
    ///
    /// - Parameters:
    ///   - whenAlreadyLinked: the answer when the document already links the
    ///     dragged item (`.sharedPlusLink`).
    ///   - whenAlreadyContained: the answer when the item already lives in the
    ///     document's own research folder (`.pieceFolder`).
    ///
    /// **Two parameters rather than one**, because the two already-there cases
    /// are not the same act: a contained fold has an order the tree can set and
    /// a linked one does not.
    private static func into(
        documentId: String,
        dragged: ResearchItem,
        structure: [StructureItem],
        research: [ResearchItem],
        projectType: ProjectType,
        whenAlreadyLinked: Intent,
        whenAlreadyContained: Intent
    ) -> Intent {
        guard let document = TreeWalk.find(id: documentId, in: structure) else {
            return .refuse(.unknownId)
        }
        guard let routing = try? ProjectStore.researchRouting(
            for: document, projectType: projectType) else {
            return .refuse(.notAResearchTarget)
        }
        switch routing {
        case .sharedOnly:
            return .refuse(.sharedOnly)
        case .sharedPlusLink(let docId):
            guard !(document.linkedResearchIds ?? []).contains(dragged.id) else {
                return whenAlreadyLinked
            }
            // The note does not move: a novel chapter's research is a LINK, so
            // the item stays exactly where it lives in shared research.
            return .link(researchId: dragged.id, toDocumentId: docId)
        case .pieceFolder(let pieceId):
            guard owningPieceId(of: dragged.id, structure: structure,
                                research: research) != pieceId else {
                return whenAlreadyContained
            }
            // Containment: the file moves into `pieces/<slug>/research/`.
            return .rescope(ids: [dragged.id], to: .piece(pieceId))
        }
    }

    /// A research item dropped on the shared Research section — the reverse of
    /// `into`, and the one place a link is REMOVED by a drag.
    ///
    /// **Links are answered first.** In a novel every research item lives in
    /// shared research whether or not a chapter links it, so "is it linked" is
    /// the only question the drop can be about; a linked note dragged out of a
    /// fold is asking to leave that chapter, and answering "move it to the
    /// shared root" instead would leave it sitting in the fold it was dragged
    /// out of.
    private static func outOfScope(
        dragged: ResearchItem,
        structure: [StructureItem],
        research: [ResearchItem],
        projectType: ProjectType
    ) -> Intent {
        // Only documents whose routing actually USES links count — a stray
        // `linkedResearchIds` on a Collection piece (legacy data; the
        // Collection's own scope is its folder) must not turn a scope move
        // into an unlink.
        let linking = TreeWalk.collect(in: structure) {
            ($0.linkedResearchIds ?? []).contains(dragged.id)
        }.filter {
            if case .sharedPlusLink = try? ProjectStore.researchRouting(
                for: $0, projectType: projectType) { return true }
            return false
        }
        if linking.count > 1 { return .refuse(.ambiguousSource) }
        if let only = linking.first {
            return .unlink(researchId: dragged.id, fromDocumentId: only.id)
        }
        // Unlinked: the section IS the shared root, so the drop lifts the item
        // out of a piece's folder or out of whatever group it was in.
        let isSharedRoot = owningPieceId(of: dragged.id, structure: structure,
                                         research: research) == nil
            && research.contains { $0.id == dragged.id }
        guard !isSharedRoot else { return .refuse(.alreadyThere) }
        return .rescope(ids: [dragged.id], to: .sharedRoot)
    }

    // MARK: - Where things live

    /// The Collection loose piece owning this research item, or nil for shared.
    /// The item's ROOT ancestor carries the reliable path (a nested link has
    /// none of its own), which is what `researchRootPath` is for.
    private static func owningPieceId(
        of id: String, structure: [StructureItem], research: [ResearchItem]
    ) -> String? {
        ProjectStore.researchScopePieceId(
            ofPath: ProjectStore.researchRootPath(ofItemId: id, in: research),
            structure: structure)
    }

    /// The move destination that means "beside this row": its parent group, or
    /// the root of the scope the row is in.
    ///
    /// Not `private` since stage-2b Task 3: a BATCH reorder has to name its
    /// destination to the plural mover, and *"beside this row"* is this rule and
    /// must not be spelled a second time in the performer — the piece-root case,
    /// where a `nil` parent id reads as the shared root, is exactly the one a
    /// re-derivation gets wrong (`BinderTreeVerbs.reorder`).
    static func container(
        ofRow id: String, structure: [StructureItem], research: [ResearchItem]
    ) -> ResearchMoveTarget {
        if let parent = TreeWalk.first(in: research, where: {
            ($0.children ?? []).contains { $0.id == id }
        }) {
            return .group(parent.id)
        }
        if let piece = owningPieceId(of: id, structure: structure,
                                     research: research) {
            return .piece(piece)
        }
        return .sharedRoot
    }

    // MARK: - A drop from outside the app (stage-2b Task 4)

    /// Where an external drop's files are imported, as the store verb that
    /// takes them.
    ///
    /// **Three destinations because there are three store verbs**, and the
    /// difference between them is what a project type MEANS by a document's
    /// research — the same distinction `ProjectStore.researchRouting` already
    /// draws for the internal side, asked rather than restated.
    enum ExternalDestination: Equatable {
        /// `ProjectStore.importResearchFiles(_:toParentId:)`. `nil` is the
        /// shared root; an id is a group, **wherever that group lives** — a
        /// group inside a Collection piece's folder is still a group, and
        /// importing into it lands in the piece.
        case sharedGroup(String?)
        /// `ProjectStore.importPieceResearchFiles(pieceId:urls:)` — the file
        /// itself goes into `pieces/<slug>/research/`.
        case piece(String)
        /// Import into shared research, then link every imported item to this
        /// document. **One act**: a novel chapter's research is a link, so
        /// there is no folder of the chapter's own to import into, and an
        /// import that stopped at shared research would leave the writer's
        /// file in the section they did not aim at.
        case sharedAndLink(String)
    }

    /// What an external drop means. `.refuse` carries the same `Reason` the
    /// internal side does — a bounce that says why.
    enum ExternalIntent: Equatable {
        case importFiles(ExternalDestination)
        case refuse(Reason)
    }

    /// **What a Finder file or a browser bitmap dropped on the tree means.**
    ///
    /// **It takes no payload id, and that is the whole difference from
    /// `classify`.** An internal drag carries something the project can look
    /// up; an external one carries a file the project has never seen. So the
    /// TARGET is the entire question, and getting it wrong does not misplace a
    /// row — it files the writer's photograph in a scope they did not aim at,
    /// where the only way back is to find it and move it.
    ///
    /// The `position` matters for exactly one case: `.middle` on a group row
    /// means *into that group*, which is the same gesture that moves a note
    /// into one. Every other position beside a row means that row's CONTAINER,
    /// which is `container(ofRow:)` — the rule the internal side already uses
    /// for "beside this row", called here rather than spelled a second time.
    static func classifyExternal(
        target: Target,
        position: DropIntent.Position,
        structure: [StructureItem],
        research: [ResearchItem],
        projectType: ProjectType
    ) -> ExternalIntent {
        switch target {
        case .sharedSection:
            return .importFiles(.sharedGroup(nil))

        case .pieceRow(let documentId):
            return intoDocument(documentId, structure: structure,
                                projectType: projectType)

        case .researchRow(let rowId):
            guard let row = TreeWalk.find(id: rowId, in: research) else {
                // A stale row is NOT the shared root. Falling back to it would
                // accept the drop and import the writer's file somewhere they
                // never pointed at, which is the silent-no-op finding wearing
                // a worse outcome.
                return .refuse(.unknownId)
            }
            if position == .middle, row.type == .group {
                return .importFiles(.sharedGroup(rowId))
            }
            return importing(besideRow: rowId, structure: structure,
                             research: research)

        case .foldRow(let rowId, let documentId):
            // A group inside a fold is a real destination — a Collection
            // piece's own group lives in that piece's folder, so importing
            // into it lands where the writer aimed. Everything else in a fold
            // means what the piece row above it means, which is why the fold's
            // rows carry their document at all.
            if position == .middle,
               TreeWalk.find(id: rowId, in: research)?.type == .group {
                return .importFiles(.sharedGroup(rowId))
            }
            return intoDocument(documentId, structure: structure,
                                projectType: projectType)
        }
    }

    /// Files dropped **onto** a document — its piece row, or a row in its fold.
    /// What that means is the document's own research routing.
    private static func intoDocument(
        _ documentId: String, structure: [StructureItem], projectType: ProjectType
    ) -> ExternalIntent {
        guard let document = TreeWalk.find(id: documentId, in: structure) else {
            return .refuse(.unknownId)
        }
        guard let routing = try? ProjectStore.researchRouting(
            for: document, projectType: projectType) else {
            return .refuse(.notAResearchTarget)
        }
        switch routing {
        case .sharedOnly:
            return .refuse(.sharedOnly)
        case .sharedPlusLink(let docId):
            return .importFiles(.sharedAndLink(docId))
        case .pieceFolder(let pieceId):
            return .importFiles(.piece(pieceId))
        }
    }

    /// The destination that means "beside this row" — `container(ofRow:)`'s
    /// answer, in the store verb that takes files rather than the one that
    /// moves items.
    ///
    /// Deliberately **not** named `importFiles`: that is the `ExternalIntent`
    /// case, and a static function of the same name shadows it at every
    /// leading-dot call site inside this type. The compiler said so.
    private static func importing(
        besideRow id: String, structure: [StructureItem], research: [ResearchItem]
    ) -> ExternalIntent {
        switch container(ofRow: id, structure: structure, research: research) {
        case .group(let groupId): return .importFiles(.sharedGroup(groupId))
        case .piece(let pieceId): return .importFiles(.piece(pieceId))
        case .sharedRoot: return .importFiles(.sharedGroup(nil))
        }
    }
}
