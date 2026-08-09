import XCTest
import MaughamCore
@testable import Maugham

/// **What a drag onto the binder tree MEANS** (shell-finish stage-2a Task 7).
///
/// The milestone gives every persona one left column, so the tree now holds
/// manuscript rows, research rows, per-piece folds and a shared Research
/// section in one list — and a drag across it is how a writer says *this
/// belongs to that*. `TreeDropIntent.classify` is the one place that decides
/// what a drop means; everything downstream only performs it.
///
/// **Pure, and exhaustively asked.** The classifier takes manifest values, not
/// a store, so the whole grid — every target × a research id, a structure id
/// and an id belonging to neither × every project type — is a table here rather
/// than a mounted drag. That matters because a real drag session is not
/// synthesisable headless: if the routing is not correct in a pure function, no
/// test in this repo can see it at all.
///
/// **Routing is by LOOKUP, never by the shape of an id.** The last test in this
/// file is the falsifier for that claim: it runs a plausible id-shape
/// classifier over the same grid and asserts the grid can tell the two apart.
final class TreeDropIntentTests: XCTestCase {

    // MARK: - The four project types, as fixtures

    /// A novel: two chapters, chapter 1 links `linkedNote`, shared research
    /// holds `note`, `linkedNote`, and a group with `nestedNote` in it.
    private struct Novel {
        static let type = ProjectType.novel
        static let structure: [StructureItem] = [
            StructureItem(id: "ch1", title: "One", type: .document,
                          path: "manuscript/01-one.md",
                          linkedResearchIds: ["linked"]),
            StructureItem(id: "ch2", title: "Two", type: .document,
                          path: "manuscript/02-two.md"),
            StructureItem(id: "grp", title: "Part I", type: .group, children: [
                StructureItem(id: "ch3", title: "Three", type: .document,
                              path: "manuscript/03-three.md")
            ])
        ]
        static let research: [ResearchItem] = [
            ResearchItem(id: "note", title: "Ships", type: .asset,
                         kind: .document, path: "research/ships.md"),
            ResearchItem(id: "linked", title: "Tides", type: .asset,
                         kind: .document, path: "research/tides.md"),
            ResearchItem(id: "group", title: "World", type: .group,
                         path: "research/world", children: [
                            ResearchItem(id: "nested", title: "Maps", type: .asset,
                                         kind: .document,
                                         path: "research/world/maps.md")
                         ])
        ]
    }

    /// A collection: two loose pieces and one reference piece. `pieceNote`
    /// lives in piece A's folder; `note` and `group`/`nested` are shared.
    private struct Collection {
        static let type = ProjectType.collection
        static let structure: [StructureItem] = [
            StructureItem(id: "pA", title: "A", type: .document,
                          path: "pieces/01-a/01-a.md", pieceKind: .loose),
            StructureItem(id: "pB", title: "B", type: .document,
                          path: "pieces/02-b/02-b.md", pieceKind: .loose),
            StructureItem(id: "pRef", title: "Elsewhere", type: .document,
                          path: "pieces/03-elsewhere", pieceKind: .reference)
        ]
        static let research: [ResearchItem] = [
            ResearchItem(id: "note", title: "Ships", type: .asset,
                         kind: .document, path: "research/ships.md"),
            ResearchItem(id: "group", title: "World", type: .group,
                         path: "research/world", children: [
                            ResearchItem(id: "nested", title: "Maps", type: .asset,
                                         kind: .document,
                                         path: "research/world/maps.md")
                         ]),
            ResearchItem(id: "pieceNote", title: "A's own", type: .asset,
                         kind: .document,
                         path: "pieces/01-a/research/own.md"),
            // A second note in the SAME piece folder, so a reorder within one
            // contained fold has two rows to be about (finding I1's control).
            ResearchItem(id: "pieceNote2", title: "A's other", type: .asset,
                         kind: .document,
                         path: "pieces/01-a/research/other.md")
        ]
    }

    /// A short story (and, structurally, a screenplay): one document, all
    /// research shared.
    private struct Single {
        static let structure: [StructureItem] = [
            StructureItem(id: "doc", title: "The Story", type: .document,
                          path: "manuscript/story.md")
        ]
        static let research: [ResearchItem] = [
            ResearchItem(id: "note", title: "Ships", type: .asset,
                         kind: .document, path: "research/ships.md"),
            ResearchItem(id: "other", title: "Tides", type: .asset,
                         kind: .document, path: "research/tides.md")
        ]
    }

    // MARK: - Into a piece row

    func test_aNoteDroppedOnANovelChapterIsLinkedToIt() {
        XCTAssertEqual(
            classify("note", on: .pieceRow("ch1"), in: Novel.self),
            .link(researchId: "note", toDocumentId: "ch1"),
            "a novel's chapter research is shared-plus-link, so dropping a note "
            + "on a chapter is the link — the note stays exactly where it lives")
    }

    func test_aNoteAlreadyLinkedToThatChapterIsRefused() {
        XCTAssertEqual(
            classify("linked", on: .pieceRow("ch1"), in: Novel.self),
            .refuse(.alreadyThere),
            "linking is idempotent in the store, so accepting would animate a "
            + "drop that changes nothing. A bounce says so")
    }

    func test_theSameNoteDroppedOnTheOtherChapterStillLinks() {
        XCTAssertEqual(
            classify("linked", on: .pieceRow("ch2"), in: Novel.self),
            .link(researchId: "linked", toDocumentId: "ch2"),
            "control for the refusal above: 'already there' is about THIS "
            + "chapter, not about the note")
    }

    func test_aNoteDroppedOnACollectionPieceMovesIntoItsFolder() {
        XCTAssertEqual(
            classify("note", on: .pieceRow("pA"), in: Collection.self),
            .rescope(ids: ["note"], to: .piece("pA")),
            "a collection piece's research is CONTAINMENT — the note's file "
            + "moves into pieces/01-a/research/")
    }

    func test_aPiecesOwnNoteDroppedBackOnThatPieceIsRefused() {
        XCTAssertEqual(
            classify("pieceNote", on: .pieceRow("pA"), in: Collection.self),
            .refuse(.alreadyThere))
    }

    func test_aPiecesNoteDroppedOnTheOtherPieceMovesScope() {
        XCTAssertEqual(
            classify("pieceNote", on: .pieceRow("pB"), in: Collection.self),
            .rescope(ids: ["pieceNote"], to: .piece("pB")))
    }

    func test_aReferencePieceRefusesResearchAltogether() {
        XCTAssertEqual(
            classify("note", on: .pieceRow("pRef"), in: Collection.self),
            .refuse(.notAResearchTarget),
            "a referenced piece keeps its research in its own project — this is "
            + "ProjectStore.researchRouting's refusal, not a second rule here")
    }

    func test_aStructureGroupIsNotAResearchTarget() {
        XCTAssertEqual(
            classify("note", on: .pieceRow("grp"), in: Novel.self),
            .refuse(.notAResearchTarget))
    }

    func test_aSingleDocumentTypeRefusesAPieceScopedDrop() {
        for type in [ProjectType.shortStory, .screenplay] {
            XCTAssertEqual(
                TreeDropIntent.classify(
                    payloadId: "note", target: .pieceRow("doc"),
                    structure: Single.structure, research: Single.research,
                    projectType: type),
                .refuse(.sharedOnly),
                "\(type): everything is already the document's, so there is no "
                + "scope for the drop to change")
        }
    }

    // MARK: - Out to the shared section

    func test_aLinkedNoteDraggedToTheSharedSectionLeavesItsChapter() {
        XCTAssertEqual(
            classify("linked", on: .sharedSection, in: Novel.self),
            .unlink(researchId: "linked", fromDocumentId: "ch1"),
            "the reverse of the chapter drop: out of the fold, out of the link")
    }

    func test_aNoteLinkedToTwoChaptersRefusesRatherThanGuess() {
        var structure = Novel.structure
        structure[1].linkedResearchIds = ["linked"]
        XCTAssertEqual(
            TreeDropIntent.classify(
                payloadId: "linked", target: .sharedSection,
                structure: structure, research: Novel.research,
                projectType: .novel),
            .refuse(.ambiguousSource),
            "the drag payload is a bare id — nothing in it says which fold the "
            + "writer dragged FROM, and unlinking the wrong chapter (or all of "
            + "them) is a link deletion they never asked for")
    }

    func test_aSharedRootNoteDroppedOnTheSharedSectionIsRefused() {
        XCTAssertEqual(
            classify("note", on: .sharedSection, in: Novel.self),
            .refuse(.alreadyThere),
            "it is already a root of shared research; the drop changes nothing")
    }

    func test_aNoteInsideAGroupDraggedToTheSharedSectionComesOutOfIt() {
        XCTAssertEqual(
            classify("nested", on: .sharedSection, in: Novel.self),
            .rescope(ids: ["nested"], to: .sharedRoot),
            "the section IS the shared root, so dropping on it lifts an item "
            + "out of whatever group it was in")
    }

    func test_aPiecesNoteDraggedToTheSharedSectionBecomesShared() {
        XCTAssertEqual(
            classify("pieceNote", on: .sharedSection, in: Collection.self),
            .rescope(ids: ["pieceNote"], to: .sharedRoot))
    }

    // MARK: - Onto another research row

    func test_twoSharedNotesReorder() {
        XCTAssertEqual(
            classify("note", on: .researchRow("linked"), in: Novel.self),
            .researchReorder,
            "same scope: this is the ordinary reorder every research surface "
            + "has always had, and the tree delegates it to the same mover")
    }

    func test_aRowDroppedOnItselfIsRefused() {
        XCTAssertEqual(
            classify("note", on: .researchRow("note"), in: Novel.self),
            .refuse(.sameRow))
    }

    func test_aPiecesNoteDroppedOnASharedRowChangesScope() {
        XCTAssertEqual(
            classify("pieceNote", on: .researchRow("note"), in: Collection.self),
            .rescope(ids: ["pieceNote"], to: .sharedRoot),
            "cross-scope: the target row's container is where it lands")
    }

    func test_aPiecesNoteDroppedOnARowInsideAGroupJoinsThatGroup() {
        XCTAssertEqual(
            classify("pieceNote", on: .researchRow("nested"), in: Collection.self),
            .rescope(ids: ["pieceNote"], to: .group("group")),
            "the container of a row inside a group is the group — dropping "
            + "beside a row must not land the item somewhere the writer can't "
            + "see it")
    }

    /// **A group row is a destination** (stage 2b final review's I4).
    ///
    /// It used to answer `container(ofRow: "group")` — the group's own parent,
    /// which for a root group is the shared root — so a note dragged out of a
    /// piece and dropped ON "World" landed beside it, while a Finder file
    /// dropped on the same row at the same pixel went INTO it
    /// (`test_aFileDroppedIntoAGroupRowLandsInThatGroup`), and the research pane
    /// this tree replaced read middle-on-group as *into the group* too. Two
    /// answers to one question, and the one this fixed is the answer that files
    /// the writer's note where they were not pointing.
    func test_aPiecesNoteDroppedOnAGroupRowJoinsThatGroup() {
        XCTAssertEqual(
            classify("pieceNote", on: .researchRow("group"), in: Collection.self),
            .rescope(ids: ["pieceNote"], to: .group("group")),
            "dropped ON a group — the same reading the external classifier and "
            + "the old pane both give the same gesture")
    }

    /// The control that keeps the rule about GROUPS rather than about rows: a
    /// leaf target still means beside it, which for a root-level note is the
    /// shared root.
    func test_aPiecesNoteDroppedOnALeafRowStillLandsBesideIt() {
        XCTAssertEqual(
            classify("pieceNote", on: .researchRow("note"), in: Collection.self),
            .rescope(ids: ["pieceNote"], to: .sharedRoot),
            "a leaf is a neighbour, not a container — this is the cell the "
            + "group rule must not swallow")
    }

    /// And the other control: within one scope a group row is still a REORDER,
    /// untouched. The group rule is about the cross-scope arm alone, because a
    /// same-scope drop is the ordinary reorder every research surface has always
    /// had and its position is the performer's to compute.
    func test_aSharedNoteDroppedOnASharedGroupRowIsStillTheOrdinaryReorder() {
        XCTAssertEqual(
            classify("note", on: .researchRow("group"), in: Novel.self),
            .researchReorder,
            "same scope: nothing about the scope changes, so this is the "
            + "reorder — the group rule must not reach into it")
    }

    func test_aRowWhoseTargetDoesNotExistIsRefused() {
        XCTAssertEqual(
            classify("note", on: .researchRow("ghost"), in: Novel.self),
            .refuse(.unknownId))
    }

    // MARK: - Onto a row inside a piece's fold

    func test_aNoteDroppedInsideAChaptersFoldLinksToThatChapter() {
        XCTAssertEqual(
            classify("note", on: .foldRow(rowId: "linked", documentId: "ch1"),
                     in: Novel.self),
            .link(researchId: "note", toDocumentId: "ch1"),
            "a fold row is a near-miss of the piece row above it, and it means "
            + "the same thing: this belongs to that chapter")
    }

    /// **A reorder inside a novel chapter's fold is refused** (final-review
    /// finding I1). It used to be `.researchReorder`, and the reorder the tree
    /// performs is `ProjectStore.moveResearchItem` over SHARED research — while
    /// the fold draws the chapter's `linkedResearchIds`, whose order that call
    /// cannot touch. So the drop was accepted, the fold did not move, and rows
    /// the writer was not looking at were reordered in the section below.
    func test_aNoteAlreadyLinkedToThatChapterRefusesARowLevelReorder() {
        XCTAssertEqual(
            classify("linked", on: .foldRow(rowId: "note", documentId: "ch1"),
                     in: Novel.self),
            .refuse(.linkedFoldHasNoOrder),
            "a linked fold has no order of its own to set — accepting this "
            + "reorders shared research behind the writer's back and leaves the "
            + "fold exactly as it was")
    }

    /// The other half, and what stops the refusal above being a blanket "folds
    /// don't reorder": a Collection piece's fold is real containment, its rows
    /// live in the piece's own `research/`, and their order is the tree's to
    /// set.
    func test_aNoteAlreadyInACollectionPiecesFoldStillReorders() {
        XCTAssertEqual(
            classify("pieceNote", on: .foldRow(rowId: "pieceNote2", documentId: "pA"),
                     in: Collection.self),
            .researchReorder,
            "a contained fold has an order and `moveResearchItem` sets it")
    }

    func test_aSharedNoteDroppedInsideACollectionPiecesFoldJoinsThePiece() {
        XCTAssertEqual(
            classify("note", on: .foldRow(rowId: "pieceNote", documentId: "pA"),
                     in: Collection.self),
            .rescope(ids: ["note"], to: .piece("pA")))
    }

    func test_aFoldRowDroppedOnItselfIsRefused() {
        XCTAssertEqual(
            classify("linked", on: .foldRow(rowId: "linked", documentId: "ch1"),
                     in: Novel.self),
            .refuse(.sameRow))
    }

    // MARK: - Ids that are not research

    func test_aChapterDraggedOntoAnotherChapterIsTheStructureReorder() {
        XCTAssertEqual(
            classify("ch2", on: .pieceRow("ch1"), in: Novel.self),
            .structureReorder,
            "the binder's own reorder, untouched by this task — the tree "
            + "delegates to DropIntent.classify/moveStructureItem")
    }

    func test_aChapterDroppedOnItselfIsRefusedRatherThanAcceptedAsANoOp() {
        XCTAssertEqual(
            classify("ch1", on: .pieceRow("ch1"), in: Novel.self),
            .refuse(.sameRow),
            "BinderView's reorder guards this and returns, so accepting would "
            + "be the accepted-drop animation over nothing at all")
    }

    func test_aChapterDroppedOnARowThatIsNotThereIsRefused() {
        XCTAssertEqual(
            classify("ch2", on: .pieceRow("ghost"), in: Novel.self),
            .refuse(.unknownId))
    }

    func test_aChapterDraggedOntoResearchIsRefused() {
        for target in [TreeDropIntent.Target.sharedSection,
                       .researchRow("note"),
                       .foldRow(rowId: "linked", documentId: "ch1")] {
            XCTAssertEqual(
                classify("ch2", on: target, in: Novel.self),
                .refuse(.structureOntoResearch),
                "\(target): a research row is not a position in the "
                + "manuscript, so there is no reorder for the drop to be")
        }
    }

    func test_anIdBelongingToNeitherTreeIsRefusedEverywhere() {
        for target in [TreeDropIntent.Target.pieceRow("ch1"), .sharedSection,
                       .researchRow("note"),
                       .foldRow(rowId: "linked", documentId: "ch1")] {
            XCTAssertEqual(
                classify("who-knows", on: target, in: Novel.self),
                .refuse(.unknownId),
                "\(target): an id from somewhere else — the canvas, another "
                + "window, a stale drag — must bounce, loudly and visibly, "
                + "rather than being accepted and doing nothing")
        }
    }

    // MARK: - A Finder file or a browser bitmap (stage-2b Task 4)

    /// **The external half of the same question**, and it is a different one.
    ///
    /// An internal drag carries an id the classifier can look up, so it always
    /// knows what is moving. A Finder file carries nothing the project has ever
    /// seen — there is only the TARGET, and the target alone has to say which
    /// scope the files land in and by which store verb. So the answer is a
    /// destination rather than a move: the shared tree (root or a group), a
    /// Collection piece's own folder, or shared-plus-a-link for a novel
    /// chapter, whose research is a link and never a file in its folder.
    ///
    /// Same reason it is a pure function as the internal side: a real drag
    /// session is not synthesisable headless, so if the routing is not right
    /// here, no test in this repo can see it.

    func test_aFileDroppedOnTheResearchSectionImportsToTheSharedRoot() {
        XCTAssertEqual(
            classifyExternal(on: .sharedSection, in: Novel.self),
            .importFiles(.sharedGroup(nil)),
            "the section IS the shared root — its header and the placeholder an "
            + "empty section shows are the same target")
    }

    func test_aFileDroppedOnANovelChapterIsImportedToSharedAndLinked() {
        XCTAssertEqual(
            classifyExternal(on: .pieceRow("ch1"), in: Novel.self),
            .importFiles(.sharedAndLink("ch1")),
            "a novel chapter's research is a LINK, so the file has nowhere of "
            + "the chapter's own to be imported into: it lands in shared "
            + "research and the link is what makes it the chapter's — one act")
    }

    func test_aFileDroppedInsideAChaptersFoldMeansWhatTheChapterRowMeans() {
        XCTAssertEqual(
            classifyExternal(on: .foldRow(rowId: "linked", documentId: "ch1"),
                             position: .bottom, in: Novel.self),
            .importFiles(.sharedAndLink("ch1")),
            "the fold is a near-miss of the piece row above it and means the "
            + "same thing — which is why the fold's rows carry their document")
    }

    func test_aFileDroppedOnACollectionPieceImportsIntoThatPiecesFolder() {
        XCTAssertEqual(
            classifyExternal(on: .pieceRow("pA"), in: Collection.self),
            .importFiles(.piece("pA")),
            "a Collection piece's research is CONTAINMENT, so the file is "
            + "imported into pieces/01-a/research/ — `importPieceResearchFiles`")
    }

    func test_aFileDroppedInsideACollectionPiecesFoldImportsIntoThatPiece() {
        XCTAssertEqual(
            classifyExternal(on: .foldRow(rowId: "pieceNote", documentId: "pA"),
                             position: .top, in: Collection.self),
            .importFiles(.piece("pA")))
    }

    func test_aFileDroppedIntoAGroupRowLandsInThatGroup() {
        XCTAssertEqual(
            classifyExternal(on: .researchRow("group"), position: .middle,
                             in: Novel.self),
            .importFiles(.sharedGroup("group")),
            "dropped ON a group — the same gesture that moves a note into one")
    }

    func test_aFileDroppedBesideAGroupRowLandsBesideIt() {
        XCTAssertEqual(
            classifyExternal(on: .researchRow("group"), position: .top,
                             in: Novel.self),
            .importFiles(.sharedGroup(nil)),
            "control for the case above: the top third of a group row is "
            + "*beside* it, and beside a root group is the shared root")
    }

    func test_aFileDroppedBesideANestedRowLandsInThatRowsGroup() {
        XCTAssertEqual(
            classifyExternal(on: .researchRow("nested"), position: .bottom,
                             in: Novel.self),
            .importFiles(.sharedGroup("group")),
            "beside a row means that row's container — importing to the shared "
            + "root would put the file where the writer was not looking")
    }

    func test_aFileDroppedBesideAPiecesOwnRowLandsInThatPiece() {
        XCTAssertEqual(
            classifyExternal(on: .researchRow("pieceNote"), position: .bottom,
                             in: Collection.self),
            .importFiles(.piece("pA")),
            "the container rule is `TreeDropIntent.container(ofRow:)`'s, called "
            + "rather than restated — a piece-scoped row's container is its "
            + "piece, and reading its nil parent id as 'shared' is exactly the "
            + "mistake a re-derivation makes")
    }

    func test_aSingleDocumentTypeRefusesAnExternalDropOnItsScript() {
        for type in [ProjectType.shortStory, .screenplay] {
            XCTAssertEqual(
                TreeDropIntent.classifyExternal(
                    target: .pieceRow("doc"), position: .middle,
                    structure: Single.structure, research: Single.research,
                    projectType: type),
                .refuse(.sharedOnly),
                "\(type): all of its research is already the document's, so "
                + "there is no scope the drop could be asking for — and the "
                + "bounce is the same refusal an internal drag gets")
        }
    }

    func test_aReferencePieceRefusesAnExternalDropRatherThanImportingElsewhere() {
        XCTAssertEqual(
            classifyExternal(on: .pieceRow("pRef"), in: Collection.self),
            .refuse(.notAResearchTarget),
            "a referenced piece keeps its research in its own project — "
            + "importing into this one would file the writer's photograph "
            + "under a piece that cannot show it")
    }

    func test_aStructureGroupRefusesAnExternalDrop() {
        XCTAssertEqual(
            classifyExternal(on: .pieceRow("grp"), in: Novel.self),
            .refuse(.notAResearchTarget))
    }

    func test_anExternalDropOnARowTheTreeCannotFindIsRefused() {
        XCTAssertEqual(
            classifyExternal(on: .researchRow("who-knows"), in: Novel.self),
            .refuse(.unknownId),
            "a stale row is not the shared root — silently importing there is "
            + "the accept-and-file-it-somewhere-else defect")
        XCTAssertEqual(
            classifyExternal(on: .pieceRow("who-knows"), in: Novel.self),
            .refuse(.unknownId))
    }

    /// The external classifier is **total** too: every target × every position
    /// × every project type answers, without trapping.
    func test_theExternalClassifierAnswersEveryTargetInEveryProjectType() {
        var answers: [TreeDropIntent.ExternalIntent] = []
        for (_, type, structure, research) in Self.fixtures {
            let docId = structure[0].id
            let rowId = research[0].id
            // A GROUP row joined the targets in the final review's I4 fix:
            // it is the one research target whose answer is not the same
            // question as a leaf's, and the grid could not see it before.
            // Fixtures with no group repeat their leaf row, which costs a
            // duplicate probe and keeps the shape uniform.
            let groupRowId = research.first { $0.type == .group }?.id ?? rowId
            let targets: [TreeDropIntent.Target] = [
                .pieceRow(docId), .sharedSection, .researchRow(rowId),
                .researchRow(groupRowId),
                .foldRow(rowId: rowId, documentId: docId),
                .pieceRow("nobody")
            ]
            for target in targets {
                for position in [DropIntent.Position.top, .middle, .bottom] {
                    answers.append(TreeDropIntent.classifyExternal(
                        target: target, position: position,
                        structure: structure, research: research,
                        projectType: type))
                }
            }
        }
        XCTAssertEqual(answers.count, 72,
                       "four fixtures × six targets × three positions — if "
                       + "this moved, a target or a project type was added and "
                       + "the external grid should grow with it")
    }

    // MARK: - The whole grid

    /// Every target × every payload kind × every project type, asked at once.
    ///
    /// The per-case tests above say what each answer IS; this one says the
    /// classifier is **total** — it answers, without trapping, for every
    /// combination the tree can deliver, including the ones no writer is
    /// likely to produce. It is also the corpus the falsifier below runs
    /// against.
    func test_theClassifierAnswersEveryTargetForEveryPayloadInEveryProjectType() {
        var answered = 0
        for probe in Self.grid {
            _ = probe.intent
            answered += 1
        }
        XCTAssertEqual(answered, Self.grid.count)
        XCTAssertEqual(Self.grid.count, 72,
                       "four fixtures × six targets × three payload kinds — if "
                       + "this moved, a target or a project type was added and "
                       + "the grid should grow with it")
    }

    /// **The falsifier: routing is by lookup, and this proves the grid can tell.**
    ///
    /// The cheap wrong implementation is the tempting one — a research id and a
    /// chapter id look different enough that a classifier can seem to work by
    /// reading the payload's shape (a prefix, a length, a separator). It works
    /// on the fixtures its author had and fails silently on the writer's real
    /// project, where ids are opaque. So: run a plausible id-shape classifier
    /// over the same grid and require the two to DISAGREE. If they ever agree
    /// everywhere, this file has stopped testing what it says it tests.
    func test_theGridCanTellALookupApartFromAGuessAtTheIdsShape() {
        var disagreements: [String] = []
        for probe in Self.grid where probe.intent != probe.idShapeGuess {
            disagreements.append(probe.label)
        }
        XCTAssertFalse(
            disagreements.isEmpty,
            "the grid must be able to distinguish a classifier that LOOKS ids "
            + "up from one that guesses at their shape")
        XCTAssertGreaterThanOrEqual(
            disagreements.count, 8,
            "…and by more than one lucky case. Disagreed on:\n"
            + disagreements.joined(separator: "\n"))
    }

    // MARK: - The grid itself

    private struct Probe {
        let label: String
        let intent: TreeDropIntent.Intent
        let idShapeGuess: TreeDropIntent.Intent
    }

    private static let fixtures: [(String, ProjectType, [StructureItem], [ResearchItem])] = [
        ("novel", .novel, Novel.structure, Novel.research),
        ("collection", .collection, Collection.structure, Collection.research),
        ("shortStory", .shortStory, Single.structure, Single.research),
        ("screenplay", .screenplay, Single.structure, Single.research)
    ]

    private static let grid: [Probe] = {
        var probes: [Probe] = []
        for (name, type, structure, research) in fixtures {
            let docId = structure[0].id
            let rowId = research[0].id
            // A GROUP row joined the targets in the final review's I4 fix:
            // it is the one research target whose answer is not the same
            // question as a leaf's, and the grid could not see it before.
            // Fixtures with no group repeat their leaf row, which costs a
            // duplicate probe and keeps the shape uniform.
            let groupRowId = research.first { $0.type == .group }?.id ?? rowId
            let targets: [TreeDropIntent.Target] = [
                .pieceRow(docId), .sharedSection, .researchRow(rowId),
                .researchRow(groupRowId),
                .foldRow(rowId: rowId, documentId: docId),
                .pieceRow("nobody")
            ]
            // A research id, a structure id, and an id from neither tree.
            let payloads = [research.count > 1 ? research[1].id : research[0].id,
                            docId, "elsewhere-9f2c"]
            for target in targets {
                for payload in payloads {
                    probes.append(Probe(
                        label: "\(name): \(payload) → \(target)",
                        intent: TreeDropIntent.classify(
                            payloadId: payload, target: target,
                            structure: structure, research: research,
                            projectType: type),
                        idShapeGuess: idShapeClassify(
                            payloadId: payload, target: target,
                            structure: structure, research: research,
                            projectType: type)))
                }
            }
        }
        return probes
    }()

    /// **The planted offender.** A classifier that decides what a payload is
    /// from the look of the id rather than by finding it: research ids in this
    /// codebase's fixtures tend to read like nouns, structure ids like `ch1` /
    /// `pA`. Everything else about it is the real routing.
    private static func idShapeClassify(
        payloadId: String, target: TreeDropIntent.Target,
        structure: [StructureItem], research: [ResearchItem],
        projectType: ProjectType
    ) -> TreeDropIntent.Intent {
        let looksStructural = payloadId.hasPrefix("ch") || payloadId.hasPrefix("p")
        if looksStructural {
            switch target {
            case .pieceRow: return .structureReorder
            default: return .refuse(.structureOntoResearch)
            }
        }
        // Pretend it is research and route it as such — but with no lookup
        // there is no scope, no link list and no existence check.
        switch target {
        case .pieceRow(let docId):
            return .link(researchId: payloadId, toDocumentId: docId)
        case .foldRow(_, let docId):
            return .link(researchId: payloadId, toDocumentId: docId)
        case .researchRow:
            return .researchReorder
        case .sharedSection:
            return .rescope(ids: [payloadId], to: .sharedRoot)
        }
    }

    // MARK: - Helpers

    private func classify(
        _ payloadId: String, on target: TreeDropIntent.Target, in _: Novel.Type
    ) -> TreeDropIntent.Intent {
        TreeDropIntent.classify(
            payloadId: payloadId, target: target,
            structure: Novel.structure, research: Novel.research,
            projectType: Novel.type)
    }

    private func classify(
        _ payloadId: String, on target: TreeDropIntent.Target, in _: Collection.Type
    ) -> TreeDropIntent.Intent {
        TreeDropIntent.classify(
            payloadId: payloadId, target: target,
            structure: Collection.structure, research: Collection.research,
            projectType: Collection.type)
    }

    /// The external classifier takes no payload — a Finder file is nothing the
    /// project has seen — so the target and the drop's vertical position are
    /// the whole question.
    private func classifyExternal(
        on target: TreeDropIntent.Target,
        position: DropIntent.Position = .middle, in _: Novel.Type
    ) -> TreeDropIntent.ExternalIntent {
        TreeDropIntent.classifyExternal(
            target: target, position: position,
            structure: Novel.structure, research: Novel.research,
            projectType: Novel.type)
    }

    private func classifyExternal(
        on target: TreeDropIntent.Target,
        position: DropIntent.Position = .middle, in _: Collection.Type
    ) -> TreeDropIntent.ExternalIntent {
        TreeDropIntent.classifyExternal(
            target: target, position: position,
            structure: Collection.structure, research: Collection.research,
            projectType: Collection.type)
    }
}
