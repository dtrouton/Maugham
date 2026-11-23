import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **A piece row unfolds to its own research** (shell-finish stage-2a Task 6).
///
/// The milestone gives every persona one left column, so a chapter's or a
/// piece's research has to be reachable from the row it belongs to rather than
/// from a pane the writer switches to. The rule for *which* documents fold is
/// pure and lives in `TreeSectionDerivation.pieceFold` — `TreeSectionDerivationTests`
/// asks it over every project type without a window. What cannot be asked there
/// is whether the tree actually draws a disclosure triangle, whether the row
/// under it is still the piece row, and whether a folded research row reaches
/// the window's subject through a real `List(selection:)`. That is this suite,
/// and it is mounted for the reason `BinderProjectRowTests` records: a row's
/// whole implementation is a label and a `.tag`, and whether the list matches
/// that tag is exactly what a test built from the view's own data cannot see.
///
/// The list a `List(.sidebar)` builds is an `NSOutlineView`, so "has a chevron"
/// is `isExpandable(_:)` and "unfolds" is `expandItem(_:)` — the real
/// disclosure, not a proxy for it.
@MainActor
final class BinderPieceFoldTests: XCTestCase {

    private var temp: TempDirectory!
    private var windows: [NSWindow] = []
    private var documentStores: [DocumentStore] = []

    override func setUp() async throws {
        temp = TempDirectory()
    }

    override func tearDown() async throws {
        for window in windows { window.contentView = NSView(frame: .zero) }
        pump(0.05)
        windows.removeAll()
        for ds in documentStores { await ds.close() }
        documentStores.removeAll()
        temp.cleanup()
        temp = nil
    }

    // MARK: - The novel chapter's fold (linked)

    func test_aNovelChapterUnfoldsToItsLinkedResearch() async throws {
        let store = try await novel()
        let chapter = try XCTUnwrap(store.manifest.structure.first)
        let note = try await store.addResearchTextNote(parentId: nil, title: "Tides")
        try await store.linkResearch(researchId: note.id, toDocumentId: chapter.id)

        let (window, probe) = try await hostBinder(store: store)
        let outline = try XCTUnwrap(outlineView(in: window))
        let before = outline.numberOfRows

        try expandRow(1 + TreeFurniture.topRows, in: outline)

        XCTAssertEqual(outline.numberOfRows, before + 1,
                       "the chapter unfolds to the one item linked to it")
        await select(row: 2 + TreeFurniture.topRows, in: outline,
                     until: { probe.subject == .research(note.id) })
        XCTAssertEqual(probe.subject, .research(note.id),
                       "a folded research row is a subject of the window like "
                       + "any other row in the tree")
    }

    /// **The row under the chevron is still the chapter.** The fold must not
    /// cost the piece row anything it already does, and the first thing it
    /// could cost is being the subject: a `DisclosureGroup` tags the group, not
    /// its label, so a tag left on the label would have made the chapter
    /// unclickable in exactly the projects that have research.
    func test_aFoldedChapterRowIsStillTheChaptersOwnSubject() async throws {
        let store = try await novel()
        let chapter = try XCTUnwrap(store.manifest.structure.first)
        let note = try await store.addResearchTextNote(parentId: nil, title: "Tides")
        try await store.linkResearch(researchId: note.id, toDocumentId: chapter.id)

        let (window, probe) = try await hostBinder(store: store)
        let outline = try XCTUnwrap(outlineView(in: window))

        await select(row: 1 + TreeFurniture.topRows, in: outline, until: { probe.subject == .item(chapter.id) })
        XCTAssertEqual(probe.subject, .item(chapter.id))
    }

    /// **No links yet, no chevron.** The fold is still `.linked` — the semantic
    /// is about the routing, not the count — but a triangle onto nothing would
    /// be on every chapter of every novel whose writer has linked nothing.
    func test_aNovelChapterWithNothingLinkedHasNoChevron() async throws {
        let store = try await novel()
        _ = try await store.addResearchTextNote(parentId: nil, title: "Tides")

        let (window, _) = try await hostBinder(store: store)
        let outline = try XCTUnwrap(outlineView(in: window))

        XCTAssertFalse(try isExpandable(row: 1 + TreeFurniture.topRows, in: outline),
                       "shared research the chapter is not linked to must not "
                       + "put a chevron on the chapter")
    }

    /// The control for the test above, in the same tree shape: with the note
    /// linked, the very same row IS expandable. Without this, "no chevron"
    /// could be true because nothing in this list ever gets one.
    func test_control_theSameChapterRowGetsAChevronOnceSomethingIsLinked() async throws {
        let store = try await novel()
        let chapter = try XCTUnwrap(store.manifest.structure.first)
        let note = try await store.addResearchTextNote(parentId: nil, title: "Tides")
        try await store.linkResearch(researchId: note.id, toDocumentId: chapter.id)

        let (window, _) = try await hostBinder(store: store)
        let outline = try XCTUnwrap(outlineView(in: window))

        XCTAssertTrue(try isExpandable(row: 1 + TreeFurniture.topRows, in: outline))
    }

    /// **A short story's document never folds**, because everything in Research
    /// already IS that document's — folding it under the row would draw every
    /// note in the project twice.
    /// **A short story's one document folds into GROUPS, never a flat list**
    /// (shell p3 Task 7): everything in Research is that document's (the
    /// shelf's rule), so its fold would list every research asset — at any
    /// size it shows "Research (n)" and the rest collapsed, one row a group.
    func test_aShortStorysOneDocumentFoldsIntoGroups() async throws {
        let store = try await shortStory()
        _ = try await store.addResearchTextNote(parentId: nil, title: "Tides")

        let (window, _) = try await hostBinder(store: store)
        let outline = try XCTUnwrap(outlineView(in: window))
        let before = outline.numberOfRows

        try expandRow(1 + TreeFurniture.topRows, in: outline)
        XCTAssertEqual(outline.numberOfRows, before + 1,
                       "one note, one group row — not the note itself")
        let doc = try XCTUnwrap(store.manifest.structure.first { $0.type == .document })
        guard case .groups(let runs)? = PieceFoldIndex.build(store: store, projectRoot: store.url)
                .layout(of: doc.id) else {
            return XCTFail("a single-document project's fold is grouped at any size")
        }
        XCTAssertEqual(runs.map(\.group), [.research])
    }

    /// **And the screenplay navigator needs no fold work at all** — its script
    /// row is a `sharedOnly` document, so the derivation answers `.none` and
    /// there is nothing for that pane to draw. Asserted rather than assumed:
    /// the navigator is the one tree Task 6 deliberately did not touch, and a
    /// chevron there would mean it needed touching.
    func test_theScreenplayScriptRowHasNoChevron() async throws {
        let store = try await screenplay()
        _ = try await store.addResearchTextNote(parentId: nil, title: "Tides")

        let (window, _) = try await hostNavigator(store: store)
        let outline = try XCTUnwrap(outlineView(in: window))

        XCTAssertFalse(try isExpandable(row: 1 + TreeFurniture.topRows, in: outline),
                       "the script row is the screenplay's one document and it "
                       + "folds onto nothing")
    }

    // MARK: - The collection piece's fold (contained)

    func test_aCollectionPieceUnfoldsToTheResearchInItsOwnFolder() async throws {
        let store = try await collection()
        let piece = try await store.addLoosePiece(title: "Alpha", format: .markdown)
        let owned = try await store.addPieceResearchNote(
            pieceId: piece.id, title: "Alpha's Note")
        _ = try await store.addResearchTextNote(parentId: nil, title: "Shared Note")

        let (window, probe) = try await hostCollection(store: store)
        let outline = try XCTUnwrap(outlineView(in: window))
        let before = outline.numberOfRows

        try expandRow(1 + TreeFurniture.topRows, in: outline)

        XCTAssertEqual(outline.numberOfRows, before + 1,
                       "the piece unfolds to what is in its own research "
                       + "folder — and not to the shared note beside it")
        await select(row: 2 + TreeFurniture.topRows, in: outline,
                     until: { probe.subject == .research(owned.id) })
        XCTAssertEqual(probe.subject, .research(owned.id))
    }

    func test_aCollectionPieceWithNoResearchOfItsOwnHasNoChevron() async throws {
        let store = try await collection()
        _ = try await store.addLoosePiece(title: "Alpha", format: .markdown)
        _ = try await store.addResearchTextNote(parentId: nil, title: "Shared Note")

        let (window, _) = try await hostCollection(store: store)
        let outline = try XCTUnwrap(outlineView(in: window))

        XCTAssertFalse(try isExpandable(row: 1 + TreeFurniture.topRows, in: outline),
                       "the project's shared research is not this piece's")
    }

    func test_aFoldedPieceRowIsStillThePiecesOwnSubject() async throws {
        let store = try await collection()
        let piece = try await store.addLoosePiece(title: "Alpha", format: .markdown)
        _ = try await store.addPieceResearchNote(pieceId: piece.id, title: "Alpha's Note")

        let (window, probe) = try await hostCollection(store: store)
        let outline = try XCTUnwrap(outlineView(in: window))

        await select(row: 1 + TreeFurniture.topRows, in: outline, until: { probe.subject == .item(piece.id) })
        XCTAssertEqual(probe.subject, .item(piece.id))
    }

    /// **Containment is a tree, so a group inside a piece expands.** This is
    /// the one place the two fold semantics visibly differ: a group in a
    /// piece's own folder holds that piece's research, so it keeps its
    /// disclosure triangle, where a novel chapter's fold is flat.
    func test_aGroupInsideACollectionPiecesFoldExpandsToItsChildren() async throws {
        let store = try await collection()
        let piece = try await store.addLoosePiece(title: "Alpha", format: .markdown)
        let group = try await store.addResearchItem(
            parentId: nil, title: "Sources", kind: nil)
        let child = try await store.addResearchTextNote(
            parentId: group.id, title: "A Clipping")
        try await store.moveResearchItems(ids: [group.id], to: .piece(piece.id))

        let (window, probe) = try await hostCollection(store: store)
        let outline = try XCTUnwrap(outlineView(in: window))

        try expandRow(1 + TreeFurniture.topRows, in: outline)   // the piece
        XCTAssertTrue(try isExpandable(row: 2 + TreeFurniture.topRows, in: outline),
                      "the group inside the piece keeps its own triangle")
        try expandRow(2 + TreeFurniture.topRows, in: outline)   // the group

        await select(row: 3 + TreeFurniture.topRows, in: outline, until: { probe.subject == .research(child.id) })
        XCTAssertEqual(probe.subject, .research(child.id),
                       "and its child is a subject like any other row")
    }

    /// **A linked group in a novel chapter's fold opens to its notes** (shell
    /// p5 Task 4a): a group the chapter links is the chapter's, with
    /// everything in it, and it is drawn nowhere else — a flat row there would
    /// leave its notes on no row at all.
    func test_aLinkedGroupInANovelChaptersFoldOpensToItsNotes() async throws {
        let store = try await novel()
        let chapter = try XCTUnwrap(store.manifest.structure.first)
        let group = try await store.addResearchItem(
            parentId: nil, title: "Sources", kind: nil)
        _ = try await store.addResearchTextNote(parentId: group.id, title: "A Clipping")
        try await store.linkResearch(researchId: group.id, toDocumentId: chapter.id)

        let (window, _) = try await hostBinder(store: store)
        let outline = try XCTUnwrap(outlineView(in: window))

        try expandRow(1 + TreeFurniture.topRows, in: outline)
        XCTAssertTrue(try isExpandable(row: 2 + TreeFurniture.topRows, in: outline),
                      "the linked group opens under the chapter: its notes are "
                      + "the chapter's, and this is their one row")
    }

    // MARK: - The fold's disclosure is the window's (stage-3b Task 7)

    /// **The writer's own chevron round-trips through the bound state.** The
    /// fold's flag moved out of SwiftUI's private storage so the reveal could
    /// open one; the thing that must not change is the writer clicking it. Both
    /// directions, because a binding that only ever inserts would leave a fold
    /// the writer closed still marked open, and the next reveal would think it
    /// had nothing to do.
    func test_theWritersChevronRoundTripsThroughTheBoundState() async throws {
        let store = try await collection()
        let piece = try await store.addLoosePiece(title: "Alpha", format: .markdown)
        _ = try await store.addPieceResearchNote(pieceId: piece.id, title: "Alpha's Note")

        let state = BinderTreeSectionsState()
        let (window, _) = try await hostCollection(store: store, state: state)
        let outline = try XCTUnwrap(outlineView(in: window))

        try expandRow(1 + TreeFurniture.topRows, in: outline)
        XCTAssertEqual(state.expandedPieceFolds, [piece.id],
                       "the click the writer makes is what the window reads")

        try collapseRow(1 + TreeFurniture.topRows, in: outline)
        XCTAssertTrue(state.expandedPieceFolds.isEmpty,
                      "and closing is a removal — collapsing stays the writer's "
                      + "click, and the state has to be able to say 'closed'")
    }

    /// **Claude's Show on a note inside a Collection piece.** The end of the
    /// task, on the delivery path: the window's reveal, into a real mounted
    /// tree, has to leave the note's row ON SCREEN — which before this task it
    /// could not, because the fold holding it was SwiftUI's own private flag
    /// and the reveal opened the shared section instead.
    func test_aRevealOfAPieceScopedNotePutsItsRowOnScreen() async throws {
        let store = try await collection()
        let piece = try await store.addLoosePiece(title: "Alpha", format: .markdown)
        let owned = try await store.addPieceResearchNote(
            pieceId: piece.id, title: "Alpha's Note")

        let state = BinderTreeSectionsState()
        let (window, probe) = try await hostCollection(store: store, state: state)
        let outline = try XCTUnwrap(outlineView(in: window))
        let before = outline.numberOfRows

        // What `openResearchItem`/`handleShowLatestMCPNote` do beside their
        // subject write — the real method, on the real state the tree is over.
        let shown = state.reveal(owned.id, structure: store.manifest.structure,
                                 research: store.manifest.research,
                                 projectType: store.manifest.type, openPiece: nil)
        XCTAssertEqual(shown, .foldRow(researchId: owned.id, piece: piece.id))
        _ = await pumpUntil(deadline: 5) { outline.numberOfRows > before }

        XCTAssertEqual(outline.numberOfRows, before + 1,
                       "the fold opened and its row is drawn")
        await select(row: 2 + TreeFurniture.topRows, in: outline,
                     until: { probe.subject == .research(owned.id) })
        XCTAssertEqual(probe.subject, .research(owned.id),
                       "and the row on screen is the note the reveal named")
    }

    /// **The scroll half of the case above** (stage-3b Task 8). Existence was
    /// the whole of the old contract; arrival is visible now, not just true —
    /// with the piece pushed far enough down the tree that its row starts
    /// off-screen, the reveal's own scroll request has to bring it back.
    ///
    /// **The note's own row in the fold** (shell p5 Task 4a: a fold's research
    /// rows carry their fold tag as their scroll identity, so `reveal` answers
    /// the row itself rather than the piece above it).
    func test_aRevealOfAPieceScopedNotePutsItsOwnRowOnScreen() async throws {
        let store = try await collection()
        for i in 0..<60 {
            _ = try await store.addLoosePiece(title: "Filler \(i)", format: .markdown)
        }
        let piece = try await store.addLoosePiece(title: "Alpha", format: .markdown)
        let owned = try await store.addPieceResearchNote(
            pieceId: piece.id, title: "Alpha's Note")

        let state = BinderTreeSectionsState()
        let (window, _) = try await hostCollection(store: store, state: state)
        let outline = try XCTUnwrap(outlineView(in: window))
        // The project row, then every piece in insertion order — Alpha is the
        // 61st (sixty filler pieces ahead of it).
        let pieceIndex = try XCTUnwrap(
            store.manifest.structure.firstIndex(where: { $0.id == piece.id }))
        let pieceRow = 1 + pieceIndex
        XCTAssertFalse(isRowVisible(pieceRow, in: outline),
                       "premise: sixty filler pieces push Alpha's row below "
                       + "the mounted window's visible rect")

        // `reveal` itself only opens the fold — the scroll request is the
        // CALLER's write (`openResearchItem`'s own shape), so this test makes
        // it exactly as production does.
        let shown = state.reveal(owned.id, structure: store.manifest.structure,
                                 research: store.manifest.research,
                                 projectType: store.manifest.type, openPiece: nil)
        XCTAssertEqual(shown, .foldRow(researchId: owned.id, piece: piece.id))
        state.scrollRequest = shown
        await pumpUntil(deadline: 5) { self.isRowVisible(pieceRow + 1, in: outline) }

        XCTAssertTrue(isRowVisible(pieceRow + 1, in: outline),
                      "the reveal opened the fold but did not scroll the "
                      + "note's own row onto screen")
    }

    /// The two hosts bind their folds to the window's state — a source census,
    /// because the mounted pair above can only drive one host at a time and a
    /// fold left on the no-binding initialiser is a tree the reveal opens
    /// nothing in. `BinderPieceFold`'s own groups join the same set the shared
    /// section uses, which is what lets an ancestor group inside a fold open.
    func test_bothHostsBindTheirFoldsToTheWindowsState() throws {
        for (host, rowId) in [("Maugham/Views/BinderView.swift", "item.id"),
                              ("Maugham/Views/CollectionPiecesPane.swift", "piece.id")] {
            let text = try source(of: host)
            XCTAssertTrue(
                text.contains("DisclosureGroup(isExpanded: treeState.foldExpansion(of: \(rowId))"),
                "\(host): the fold's disclosure must take the window's binding")
        }
        let fold = try source(of: "Maugham/Views/BinderPieceFold.swift")
        XCTAssertTrue(
            fold.contains("expandedGroups: $state.expandedResearchGroups"),
            "a fold's own groups read the tree's set of open ids, or a reveal "
            + "can open the fold and still leave the note inside a closed group")
    }

    // MARK: - The sweep reaches a fold

    /// Task 2's sweep watches the research ids as well as the structure's, and
    /// a folded row is the first place a *research* subject can be chosen from
    /// a tree. Deleting it must leave the window pointing at the project rather
    /// than at a row that is gone.
    func test_deletingAFoldedResearchItemSweepsTheSubjectToTheProject() async throws {
        let store = try await collection()
        let piece = try await store.addLoosePiece(title: "Alpha", format: .markdown)
        let owned = try await store.addPieceResearchNote(
            pieceId: piece.id, title: "Alpha's Note")

        let (window, probe) = try await hostCollection(store: store, sweeping: true)
        let outline = try XCTUnwrap(outlineView(in: window))
        try expandRow(1 + TreeFurniture.topRows, in: outline)
        await select(row: 2 + TreeFurniture.topRows, in: outline, until: { probe.subject == .research(owned.id) })
        XCTAssertEqual(probe.subject, .research(owned.id), "precondition")

        try await store.deleteResearchItem(id: owned.id)
        _ = await pumpUntil(deadline: 5) { probe.subject == .project }

        XCTAssertEqual(probe.subject, .project,
                       "the sweep repairs a subject that named a folded row")
    }

    // MARK: - Creating from inside a fold

    /// **A note asked for from inside a fold lands in that fold.** Every verb
    /// on a fold row that names a parent group already routes correctly — the
    /// piece's groups are in `manifest.research` like any other. The hole is a
    /// row at the piece's root, whose parent id is `nil`, and `nil` means the
    /// SHARED root: without the re-route a writer right-clicking inside a
    /// piece's fold and asking for a note would get one in shared research,
    /// nowhere near the piece they asked from.
    func test_aNoteMadeFromACollectionPiecesFoldLandsInThatPiecesFolder() async throws {
        let store = try await collection()
        let piece = try await store.addLoosePiece(title: "Alpha", format: .markdown)
        _ = try await store.addPieceResearchNote(pieceId: piece.id, title: "Alpha's Note")
        let before = store.manifest.research.count

        fold(for: piece.id, in: store).actions.newNote(nil)
        _ = await pumpUntil(deadline: 5) { store.manifest.research.count > before }

        let made = try XCTUnwrap(
            TreeWalk.first(in: store.manifest.research,
                           where: { $0.title == "Untitled Note" }))
        let pieceItem = try XCTUnwrap(
            TreeWalk.find(id: piece.id, in: store.manifest.structure))
        let prefix = try XCTUnwrap(ProjectStore.pieceResearchPrefix(for: pieceItem))
        XCTAssertTrue(made.path?.hasPrefix(prefix) == true,
                      "expected the note under \(prefix), got \(made.path ?? "no path")")
    }

    /// The same rule, the other routing: a novel chapter's fold is links, so a
    /// note made there is a shared note that is linked to the chapter — which
    /// is what puts it in the fold the writer asked from.
    func test_aNoteMadeFromANovelChaptersFoldIsLinkedToThatChapter() async throws {
        let store = try await novel()
        let chapter = try XCTUnwrap(store.manifest.structure.first)
        let note = try await store.addResearchTextNote(parentId: nil, title: "Tides")
        try await store.linkResearch(researchId: note.id, toDocumentId: chapter.id)
        let before = store.manifest.research.count

        fold(for: chapter.id, in: store).actions.newNote(nil)
        _ = await pumpUntil(deadline: 5) { store.manifest.research.count > before }

        let made = try XCTUnwrap(
            TreeWalk.first(in: store.manifest.research,
                           where: { $0.title == "Untitled Note" }))
        let links = TreeWalk.find(id: chapter.id, in: store.manifest.structure)?
            .linkedResearchIds ?? []
        XCTAssertTrue(links.contains(made.id),
                      "a note made from a chapter's fold has to be IN that fold")
    }

    /// The control: a note asked for with a real parent group still lands in
    /// that group, through the tree's own bundle. The re-route is the `nil`
    /// case only — if it had swallowed the parent, every note made inside a
    /// research group from a fold row would have jumped to the piece's root.
    func test_aNoteMadeInsideAFoldsGroupStillLandsInThatGroup() async throws {
        let store = try await collection()
        let piece = try await store.addLoosePiece(title: "Alpha", format: .markdown)
        let group = try await store.addResearchItem(
            parentId: nil, title: "Sources", kind: nil)
        try await store.moveResearchItems(ids: [group.id], to: .piece(piece.id))

        fold(for: piece.id, in: store).actions.newNote(group.id)
        _ = await pumpUntil(deadline: 5) {
            TreeWalk.find(id: group.id, in: store.manifest.research)?
                .children?.isEmpty == false
        }

        let children = TreeWalk.find(id: group.id, in: store.manifest.research)?
            .children ?? []
        XCTAssertEqual(children.map(\.title), ["Untitled Note"])
    }

    // MARK: - One note, two rows, one rename field (final review, I2)

    /// **A linked note is drawn ONCE** (shell p5 Task 4a, either/or): in
    /// the chapter's fold, never also in the Research section — so Rename opens
    /// one field, there. (Before, the section drew it a second time and the
    /// fold offered no rename, finding I2.)
    func test_renamingALinkedNoteOpensExactlyOneFieldInTheWholeTree() async throws {
        let store = try await novel()
        let chapter = try XCTUnwrap(store.manifest.structure.first)
        let note = try await store.addResearchTextNote(parentId: nil, title: "Tides")
        try await store.linkResearch(researchId: note.id, toDocumentId: chapter.id)

        let state = BinderTreeSectionsState()
        let (window, _) = try await hostFoldAndSections(store: store, state: state,
                                                            documentId: chapter.id)
        let outline = try XCTUnwrap(outlineView(in: window))
        let before = outline.numberOfRows
        try expandRow(0, in: outline)
        XCTAssertEqual(outline.numberOfRows, before + 1,
                       "precondition: the chapter's fold draws the linked note")
        XCTAssertEqual(markedSubject(ofRow: 1, in: outline), .research(note.id),
                       "row 1, inside the fold, is the note")
        XCTAssertNotEqual(markedSubject(ofRow: 3, in: outline), .research(note.id),
                          "and the Research section does not draw it again")

        state.renamingItemId = note.id
        pump(0.3)

        XCTAssertEqual(
            renameFields(in: window, titled: note.title).count, 1,
            "one rename request opens one field, in the fold — the note's one row")
    }

    /// The same claim on the path that actually opens a rename without a menu:
    /// creating a note from inside a novel chapter's fold. `BinderTreeVerbs.create`
    /// sets `pendingRenameId`, the presentations modifier commits it once the row
    /// exists, and the new note — a shared note linked to the chapter — is
    /// immediately in both places at once.
    func test_aNoteMadeFromANovelChaptersFoldEndsWithOneRenameField() async throws {
        let store = try await novel()
        let chapter = try XCTUnwrap(store.manifest.structure.first)
        let existing = try await store.addResearchTextNote(parentId: nil, title: "Tides")
        try await store.linkResearch(researchId: existing.id, toDocumentId: chapter.id)
        let before = store.manifest.research.count

        let state = BinderTreeSectionsState()
        let (window, _) = try await hostFoldAndSections(store: store, state: state,
                                                        documentId: chapter.id)
        fold(for: chapter.id, in: store, state: state).actions.newNote(nil)
        _ = await pumpUntil(deadline: 5) { store.manifest.research.count > before }
        pump(0.3)

        let outline = try XCTUnwrap(outlineView(in: window))
        try expandRow(0, in: outline)
        XCTAssertEqual(
            outline.numberOfRows, 7 + TreeFurniture.emptyPalette - 2 + TreeFurniture.editions,
            "precondition — the chapter row, its fold's TWO linked notes, the "
            + "Research header and its placeholder (no whole-book research), then "
            + "the Palette header and its placeholder. The note the writer just "
            + "made is in the fold they asked from, and only there")
        XCTAssertEqual(
            renameFields(in: window, titled: "Untitled Note").count, 1,
            "creating a note opens ONE rename field — the fold's")
    }

    /// **The control: a contained fold keeps the verb.** A Collection piece's
    /// research lives in that piece's own folder and is drawn exactly once, so
    /// there is no twin to race with and nothing to take away. Without this,
    /// removing rename from every fold would pass the two tests above.
    func test_aNoteInACollectionPiecesFoldStillRenamesInPlace() async throws {
        let store = try await collection()
        let piece = try await store.addLoosePiece(title: "Alpha", format: .markdown)
        let owned = try await store.addPieceResearchNote(
            pieceId: piece.id, title: "Alpha's Note")

        let state = BinderTreeSectionsState()
        let (window, _) = try await hostFoldAndSections(store: store, state: state,
                                                        documentId: piece.id)
        let outline = try XCTUnwrap(outlineView(in: window))
        try expandRow(0, in: outline)
        XCTAssertEqual(
            outline.numberOfRows, 6 + TreeFurniture.emptyPalette - 2 + TreeFurniture.editions,
            "precondition — the piece row, its fold's one note, the Research "
            + "header and its EMPTY placeholder, then the Palette header and "
            + "its placeholder. A contained note is drawn once: it is not in "
            + "shared research at all")

        state.renamingItemId = owned.id
        pump(0.3)

        XCTAssertEqual(
            renameFields(in: window, titled: owned.title).count, 1,
            "the fold row is where this note is renamed: it is the only row it "
            + "has")
    }

    /// **The menu half**, which no headless test can open: a context menu is not
    /// synthesisable, so the assertion is that the row's Rename button is gated
    /// on the same value the field is, and that the fold hands that value the
    /// semantic. If either drifts, a writer gets a menu item that opens a field
    /// on the row's twin.
    func test_theRenameMenuItemIsGatedOnTheSameValueTheFieldIs() throws {
        let node = try source(of: "Maugham/Views/ResearchTree.swift")
        XCTAssertTrue(
            node.contains("if offersRename(item.id) {"),
            "the Rename button must be behind `offersRename` — the field and the "
            + "menu item are one decision, and a menu that offers what the row "
            + "cannot do is worse than no menu")
        XCTAssertTrue(
            node.contains("offersRename(item.id) ? $renamingItemId : .constant(nil)"),
            "…and the row's binding must be dead where it does not offer "
            + "rename, or `pendingRenameId` opens the field the menu no longer "
            + "can")

        let foldSource = try source(of: "Maugham/Views/BinderPieceFold.swift")
        XCTAssertTrue(
            foldSource.contains("homes.homes(of: $0).first == documentId"),
            "a fold offers rename on one row per item: its first home in tree "
            + "order (`ResearchHomes.homes`)")
    }

    /// **What the probe above assumes, asserted.** The two tests that count
    /// rename fields mount a fold and the shared sections over ONE
    /// `BinderTreeSectionsState`; if a host ever gave its folds a state of their
    /// own, the duplicate rename could not happen there and the probe would be
    /// testing a shape production does not have. Each host takes a single
    /// `treeState` and passes that value to both.
    ///
    /// **The state moved OUT of the hosts in stage-3a Task 4** — the window owns
    /// it now, because the tree's sections learned to close and
    /// `ProjectWindow.openResearchItem` has to be able to open the one holding a
    /// revealed item. So a host owning a state of its own is the defect this
    /// census reads for in both directions: it must take one and construct none,
    /// or the window's reveal writes a flag no mounted tree is reading.
    func test_theHostsGiveTheirFoldsAndTheirSectionsOneState() throws {
        for host in ["Maugham/Views/BinderView.swift",
                     "Maugham/Views/CollectionPiecesPane.swift"] {
            let text = try source(of: host)
            XCTAssertEqual(
                text.components(separatedBy: "BinderTreeSectionsState()").count - 1, 0,
                "\(host) must construct no sections state of its own — the "
                + "window owns it, and a private one is a tree the reveal "
                + "cannot open")
            XCTAssertTrue(text.contains("let treeState: BinderTreeSectionsState"),
                          "\(host) takes exactly one, and takes it undefaulted "
                          + "so the compiler asks every caller")
            XCTAssertTrue(text.contains("BinderTreeSections(store: store, state: treeState"),
                          "\(host): the sections take it")
            XCTAssertTrue(text.contains("BinderPieceFold(store: store, state: treeState"),
                          "\(host): and so does every fold — one rename request, "
                          + "one field, is only true while there is one state")
        }
        // The third host has no folds, so it is absent above — but it must take
        // the window's state on the same terms, or a screenplay's writer is the
        // one whose tree the reveal cannot reach.
        let navigator = try source(of: "Maugham/Views/SceneNavigatorPane.swift")
        XCTAssertEqual(
            navigator.components(separatedBy: "BinderTreeSectionsState()").count - 1, 0)
        XCTAssertTrue(navigator.contains("let treeState: BinderTreeSectionsState"))
        // And the window owns exactly one, for all three of them.
        let window = try SourceTree.windowSource()
        XCTAssertEqual(
            window.components(separatedBy: "BinderTreeSectionsState()").count - 1, 1,
            "one window, one tree, one state")
    }

    // MARK: - Fixtures

    private func source(of relativePath: String) throws -> String {
        try CanvasSourceCensus.source(at: relativePath)
    }

    private func novel() async throws -> ProjectStore {
        let url = try await ProjectFactory.createNovelProject(
            named: "Novel-\(UUID().uuidString.prefix(6))", in: temp.url)
        return try await furnish(try await ProjectStore.load(from: url))
    }

    private func shortStory() async throws -> ProjectStore {
        let url = try await ProjectFactory.createShortStoryProject(
            named: "Story-\(UUID().uuidString.prefix(6))", in: temp.url)
        return try await furnish(try await ProjectStore.load(from: url))
    }

    private func screenplay() async throws -> ProjectStore {
        let url = try await ProjectFactory.createScreenplayProject(
            named: "Screenplay-\(UUID().uuidString.prefix(6))", in: temp.url)
        return try await furnish(try await ProjectStore.load(from: url))
    }

    private func collection() async throws -> ProjectStore {
        let url = try await ProjectFactory.createCollectionProject(
            named: "Collection-\(UUID().uuidString.prefix(6))", in: temp.url)
        return try await furnish(try await ProjectStore.load(from: url))
    }

    /// Every fixture opens a `DocumentStore`: the research creators write
    /// through the typed mover and refuse outright without one.
    private func furnish(_ store: ProjectStore) async throws -> ProjectStore {
        let ds = try await DocumentStore.open(url: store.url)
        store.documentStore = ds
        documentStores.append(ds)
        await store.wordCountPopulationTask?.value
        return store
    }

    /// The fold view for a document, as its host mounts it — the same value,
    /// so the bundle these tests ask is the bundle the rows carry.
    /// - Parameter state: the host's sections state. `nil` gives the fold one of
    ///   its own, which is right for the tests that only ask its verbs a
    ///   question; the rename tests pass the state their mounted list is over.
    private func fold(for documentId: String, in store: ProjectStore,
                      state: BinderTreeSectionsState? = nil) -> BinderPieceFold {
        TreeHostFixture.foldView(
            store: store,
            state: state ?? BinderTreeSectionsState(),
            subject: .constant(.book),
            documentId: documentId,
            // The verbs do not depend on what the fold draws.
            layout: .rows([]))
    }

    // MARK: - Hosting and driving

    private func hostBinder(
        store: ProjectStore
    ) async throws -> (NSWindow, BinderSubjectProbe) {
        let probe = BinderSubjectProbe()
        let window = try await mount(AnyView(
            FoldBinderProbeView(store: store, probe: probe)))
        return (window, probe)
    }

    private func hostCollection(
        store: ProjectStore, sweeping: Bool = false,
        state: BinderTreeSectionsState? = nil
    ) async throws -> (NSWindow, BinderSubjectProbe) {
        let probe = BinderSubjectProbe()
        let window = try await mount(AnyView(
            FoldCollectionProbeView(store: store, probe: probe, sweeping: sweeping,
                                    treeState: state ?? BinderTreeSectionsState())))
        return (window, probe)
    }

    private func hostNavigator(
        store: ProjectStore
    ) async throws -> (NSWindow, BinderSubjectProbe) {
        let probe = BinderSubjectProbe()
        let documentID = TreeWalk.first(
            in: store.manifest.structure, where: { $0.type == .document })?.id
        let window = try await mount(AnyView(FoldNavigatorProbeView(
            store: store, probe: probe, documentID: documentID)))
        return (window, probe)
    }

    /// **A fold and the shared sections in ONE list, over ONE
    /// `BinderTreeSectionsState`** — which is the condition the I2 tests are
    /// about and exactly what every host does: `BinderView` and
    /// `CollectionPiecesPane` each own a single `treeState` and hand the same
    /// value to `BinderTreeSections` and to every `BinderPieceFold`
    /// (`test_theHostsGiveTheirFoldsAndTheirSectionsOneState` pins that).
    ///
    /// The state is the caller's so a test can open a rename the way production
    /// does — through `renamingItemId`/`pendingRenameId` — since a context menu
    /// is not synthesisable headless.
    private func hostFoldAndSections(
        store: ProjectStore, state: BinderTreeSectionsState, documentId: String
    ) async throws -> (NSWindow, BinderSubjectProbe) {
        let probe = BinderSubjectProbe()
        let window = try await mount(AnyView(FoldAndSectionsProbeView(
            store: store, probe: probe, state: state, documentId: documentId)))
        return (window, probe)
    }

    /// The inline rename fields showing `title` — **editable** text fields, which
    /// is what tells `ResearchRow`'s rename branch from the label branch.
    private func renameFields(in window: NSWindow, titled title: String) -> [NSTextField] {
        guard let root = window.contentView else { return [] }
        var fields: [NSTextField] = []
        collect(NSTextField.self, in: root, into: &fields)
        return fields.filter { $0.isEditable && $0.stringValue == title }
    }

    private func mount(_ root: AnyView) async throws -> NSWindow {
        let window = TestWindow.mount(root, size: CGSize(width: 320, height: 800),
                                      as: SilentTestWindow.self)
        windows.append(window)
        await pumpUntil(deadline: 5) { self.outlineView(in: window) != nil }
        // The palette section loads its cards from disk once per manifest
        // change, and the fold index is built in the hosts' `.task`, so the
        // rows each contributes arrive a turn after the list does.
        pump(0.4)
        return window
    }

    /// Unfold a row for real — `NSOutlineView.expandItem`, the same call the
    /// chevron makes — then let SwiftUI's list coordinator produce the rows.
    private func expandRow(_ row: Int, in outline: NSOutlineView) throws {
        let item = try XCTUnwrap(outline.item(atRow: row),
                                 "no row \(row) in a list of \(outline.numberOfRows)")
        XCTAssertTrue(outline.isExpandable(item),
                      "row \(row) has no disclosure triangle to open")
        outline.expandItem(item)
        pump(0.2)
    }

    /// The other half of `expandRow` — `NSOutlineView.collapseItem`, which is
    /// what the chevron does the second time it is clicked.
    private func collapseRow(_ row: Int, in outline: NSOutlineView) throws {
        let item = try XCTUnwrap(outline.item(atRow: row),
                                 "no row \(row) in a list of \(outline.numberOfRows)")
        outline.collapseItem(item)
        pump(0.2)
    }

    /// The subject a row's label mark names, if it carries one.
    private func markedSubject(ofRow row: Int, in outline: NSOutlineView) -> BinderSubject? {
        guard let view = outline.rowView(atRow: row, makeIfNecessary: true) else { return nil }
        var stack: [NSView] = [view]
        while let next = stack.popLast() {
            if let mark = next as? TreeTravelTargetView, let subject = mark.subject {
                return subject
            }
            stack.append(contentsOf: next.subviews)
        }
        return nil
    }

    private func isExpandable(row: Int, in outline: NSOutlineView) throws -> Bool {
        let item = try XCTUnwrap(outline.item(atRow: row),
                                 "no row \(row) in a list of \(outline.numberOfRows)")
        return outline.isExpandable(item)
    }

    private func select(row: Int, in outline: NSOutlineView,
                        until settled: (() -> Bool)? = nil) async {
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        if let settled {
            _ = await pumpUntil(deadline: 5, settled)
        } else {
            await waitOut(0.4)
        }
    }

    private func outlineView(in window: NSWindow) -> NSOutlineView? {
        guard let root = window.contentView else { return nil }
        var found: [NSOutlineView] = []
        collect(NSOutlineView.self, in: root, into: &found)
        return found.first
    }

    /// **Whether `row` is actually on screen** — `documentVisibleRect` is the
    /// scroll view's own answer, distinct from `numberOfRows`'s "the row
    /// exists" (stage-3b Task 8's arrival-is-visible distinction).
    private func isRowVisible(_ row: Int, in outline: NSOutlineView) -> Bool {
        guard row >= 0, row < outline.numberOfRows,
              let scrollView = outline.enclosingScrollView else { return false }
        return scrollView.documentVisibleRect.intersects(outline.rect(ofRow: row))
    }

    private func collect<T: NSView>(_ type: T.Type, in view: NSView, into out: inout [T]) {
        if let hit = view as? T { out.append(hit) }
        for sub in view.subviews { collect(type, in: sub, into: &out) }
    }
}

// MARK: - Probes

@MainActor
private struct FoldBinderProbeView: View {
    let store: ProjectStore
    let probe: BinderSubjectProbe
    let treeState = BinderTreeSectionsState()

    var body: some View {
        TreeHostFixture.binder(store: store,
                   subject: .tree(Binding(get: { probe.subject },
                                            set: { probe.subject = $0 })),
                   treeState: treeState)
    }
}

@MainActor
private struct FoldCollectionProbeView: View {
    let store: ProjectStore
    let probe: BinderSubjectProbe
    /// Attaches the window's own subject sweep (Task 2) — `ProjectWindow` is
    /// where it lives in production, so a pane mounted alone does not carry it.
    let sweeping: Bool
    @State private var renaming: String?
    /// The host's one state — the caller's since stage-3b Task 7, so a test can
    /// drive the window's `reveal` into a mounted tree and read the fold's flag
    /// back off it.
    let treeState: BinderTreeSectionsState

    var body: some View {
        let subject = Binding(get: { probe.subject },
                              set: { probe.subject = $0 })
        TreeHostFixture.collection(store: store, subject: .tree(subject),
                             renamingItemId: $renaming,
                             treeState: treeState)
            .modifier(OptionalSubjectValidation(
                store: sweeping ? store : nil, selectedSubject: subject))
    }
}

/// One `List` holding a document's fold and the shared sections, over one
/// state — `BinderView`'s own shape, reduced to the two things the I2 tests are
/// about. The views inside it are production's.
@MainActor
private struct FoldAndSectionsProbeView: View {
    let store: ProjectStore
    let probe: BinderSubjectProbe
    let state: BinderTreeSectionsState
    let documentId: String

    var body: some View {
        let subject = Binding<WindowSubject>.tree(
            Binding(get: { probe.subject }, set: { probe.subject = $0 }))
        // The hosts' own binding — a SET since stage-2b Task 3, over the same
        // state this probe already hands the fold and the sections.
        List(selection: BinderTreeSelection.binding(
                subject: subject, state: state, store: store)) {
            DisclosureGroup {
                TreeHostFixture.fold(
                    store: store, state: state, subject: subject,
                    documentId: documentId,
                    // The window's index, as the hosts look it up — rebuilt by
                    // the list's `.pieceFoldIndex` when a test asks the store
                    // to make a note.
                    layout: state.foldIndex.layout(of: documentId) ?? .rows([]))
            } label: {
                Text(TreeWalk.find(id: documentId, in: store.manifest.structure)?.title
                     ?? documentId)
            }
            .tag(TreeRowTag.subject(.item(documentId)))
            BinderTreeSections(store: store, state: state, subject: subject)
        }
        .listStyle(.sidebar)
        .binderTreeSections(store: store, state: state, subject: subject)
        .pieceFoldIndex(store: store, state: state)
    }
}

@MainActor
private struct FoldNavigatorProbeView: View {
    let store: ProjectStore
    let probe: BinderSubjectProbe
    let documentID: String?
    let treeState = BinderTreeSectionsState()

    var body: some View {
        TreeHostFixture.scenes(
            store: store,
            script: FountainTokenizer().parse("INT. KITCHEN - DAY\n\nLarry sits.\n"),
            subject: .tree(Binding(get: { probe.subject },
                                     set: { probe.subject = $0 })),
            treeState: treeState,
            onSelect: { _ in })
    }
}

/// `SubjectValidationModifier` when the test asks for it, nothing when it does
/// not — the modifier takes an optional store already, and a `nil` store is
/// exactly how `ProjectWindow` spells "no sweep yet".
@MainActor
private struct OptionalSubjectValidation: ViewModifier {
    let store: ProjectStore?
    @Binding var selectedSubject: BinderSubject?

    func body(content: Content) -> some View {
        content.modifier(SubjectValidationModifier(
            store: store, documentStore: nil, subject: .bridging($selectedSubject)))
    }
}


// MARK: - The fold's decisions (shell p3 Task 7), pure

/// What a piece's fold draws and what each of its rows does — asked of the
/// pure functions `BinderPieceFold` calls, never by pressing a row
/// (tripwire 33).
@MainActor
final class BinderPieceFoldDecisionTests: XCTestCase {

    private let structure: [StructureItem] = [
        StructureItem(id: "ch-1", title: "One", type: .document, path: "one.md"),
        StructureItem(id: "ch-2", title: "Two", type: .document, path: "two.md"),
    ]

    private func scrap(_ id: String) -> PieceFoldEntry {
        .card(PinnedReference(id: id, kind: .scrap(nodeId: id), title: "A scrap"))
    }

    func test_aFoldWithSevenEntriesShowsGroupsWithCounts() {
        let seven: [PieceFoldEntry] = [
            .research(id: "r1", title: "Tides", owned: false),
            .research(id: "r2", title: "Harbour", owned: false),
            scrap("n1"),
            .palette(id: "p1", title: "Grey"),
            .figure(id: "f1", name: "Map"),
            .link(pieceId: "ch-2", title: "Two", incoming: false),
            .link(pieceId: "ch-2", title: "Two", incoming: true),
        ]
        let index = PieceFoldIndex(entries: ["ch-1": seven, "ch-2": Array(seven.prefix(6))])
        guard case .groups(let runs)? = index.layout(of: "ch-1") else {
            return XCTFail("seven entries are groups")
        }
        XCTAssertEqual(runs.map(BinderPieceFold.groupTitle),
                       ["Research (2)", "Cards (1)", "Palette (1)", "Figures (1)", "Links (2)"])
        XCTAssertEqual(index.layout(of: "ch-2"), .rows(Array(seven.prefix(6))), "six are rows")
        // A single-document project's piece groups at any size.
        let grouped = PieceFoldIndex(entries: ["doc": Array(seven.prefix(2))], alwaysGrouped: ["doc"])
        XCTAssertEqual(grouped.layout(of: "doc"),
                       .groups([PieceFoldGroupRun(group: .research, entries: Array(seven.prefix(2)))]))
    }

    func test_anEmptyFoldHasNoChevron() {
        let index = PieceFoldIndex(entries: ["ch-1": [], "ch-2": [scrap("n1")]])
        XCTAssertNil(index.layout(of: "ch-1"), "no entries, no layout: the host draws no chevron")
        XCTAssertNil(index.layout(of: "ch-9"), "a piece the index does not hold has no fold")
        XCTAssertNotNil(index.layout(of: "ch-2"), "control: one entry folds")
        // The hosts ask the index, never the research fold's own answer.
        for host in ["Maugham/Views/BinderView.swift", "Maugham/Views/CollectionPiecesPane.swift"] {
            let text = try? SourceTree.read(host)
            XCTAssertTrue(text?.contains("if let layout = treeState.foldIndex.layout(of:") == true, host)
            XCTAssertFalse(text?.contains("showsDisclosure") == true, host)
        }
    }

    /// **Linked and owned research look alike** (shell p5 Task 4a, H): with
    /// either/or there is no twin in the Research section to tell a fold row
    /// from, so the link glyph, the quiet title and "Linked from Research" are
    /// gone; a root whose group lives elsewhere names it instead.
    func test_aFoldsResearchRowCarriesNoLinkGlyphAndNamesItsPlace() throws {
        let row = SourceScan.codeLines(of: try SourceTree.read("Maugham/Views/ResearchRow.swift"))
            .joined(separator: "\n")
        for gone in ["linkedFromResearch", "Linked from Research", "trailingGlyph", "quietTitle"] {
            XCTAssertFalse(row.contains(gone), "the row still draws \(gone)")
        }
        XCTAssertTrue(row.contains("if let caption {"), "the row names its place")
        XCTAssertEqual(ResearchRow.captionAccessibilityLabel("World / Maps"), "in World / Maps")
        let fold = SourceScan.codeLines(of: try SourceTree.read("Maugham/Views/BinderPieceFold.swift"))
            .joined(separator: "\n")
        XCTAssertTrue(fold.contains("caption: fold.homes.place(of: id)"))
        XCTAssertFalse(fold.contains("linkedFromResearch"))
    }

    func test_aCardRowPullsTheCardUpAndASecondClickPutsItAway() {
        let start = WindowSubject(open: .item("ch-1"), faces: .item("ch-1"))
        for entry in [scrap("n1"), .palette(id: "p1", title: "Grey")] {
            let up = BinderPieceFold.clicked(entry, subject: start, structure: structure,
                                             projectType: .novel)
            XCTAssertEqual(up.beside, entry.pulledUp, "a click pulls it up")
            XCTAssertEqual(up.open, start.open, "and nothing else moves")
            XCTAssertTrue(BinderPieceFold.isPulledUp(entry, subject: up), "its row draws pulled up")
            let away = BinderPieceFold.clicked(entry, subject: up, structure: structure,
                                               projectType: .novel)
            XCTAssertNil(away.beside, "a second click on the row pulled up puts it away")
            XCTAssertFalse(BinderPieceFold.isPulledUp(entry, subject: away))
        }
        // A click on ANOTHER card swaps what is up rather than putting it away.
        let up = BinderPieceFold.clicked(scrap("n1"), subject: start, structure: structure,
                                         projectType: .novel)
        XCTAssertEqual(BinderPieceFold.clicked(scrap("n2"), subject: up, structure: structure,
                                               projectType: .novel).beside,
                       .canvasScrap(nodeId: "n2"))
    }

    /// **A region's row pulls the region up** by the route a card row takes
    /// (`ClickRule.pullUp`), a second click puts it away, and its cards are
    /// rows of their own under its chevron, each pulling its card up.
    func test_aRegionRowPullsTheRegionUpAndItsCardsAreRowsOfTheirOwn() {
        let start = WindowSubject(open: .item("ch-1"), faces: .item("ch-1"))
        let cards = [PinnedReference(id: "n1", kind: .scrap(nodeId: "n1"), title: "A scrap")]
        let region = PieceFoldEntry.region(id: "rg-1", title: "Fog", cards: cards)
        XCTAssertEqual(BinderPieceFold.act(of: region), .pullUp(.canvasRegion(id: "rg-1")))
        let up = BinderPieceFold.clicked(region, subject: start, structure: structure, projectType: .novel)
        XCTAssertEqual(up, ClickRule.pullUp(.canvasRegion(id: "rg-1"), current: start),
                       "the card row's route, exactly")
        XCTAssertTrue(BinderPieceFold.isPulledUp(region, subject: up))
        XCTAssertNil(BinderPieceFold.clicked(region, subject: up, structure: structure,
                                             projectType: .novel).beside,
                     "a second click puts it away")
        // A double-click opens it in the centre: the canvas, the region selected.
        XCTAssertEqual(BinderPieceFold.doubleClicked(region, subject: up, structure: structure,
                                                     projectType: .novel, photoNode: { _ in nil }),
                       .canvas(WindowSubject(open: .canvas, faces: .canvas),
                               select: .region(CanvasRegionID("rg-1"))))
        XCTAssertEqual(region.regionCards, [scrap("n1")])
        XCTAssertEqual(BinderPieceFold.clicked(region.regionCards[0], subject: up, structure: structure,
                                               projectType: .novel).beside,
                       .canvasScrap(nodeId: "n1"), "a card under the region swaps what is up")
        // Its glyph is the index's, resolved once, and so are its cards'.
        let index = PieceFoldIndex(entries: ["ch-1": [region]])
        XCTAssertEqual(index.glyph(of: region), PieceFoldIndex.regionGlyph)
        XCTAssertEqual(index.glyph(of: scrap("n1")), PieceFoldIndex.scrapGlyph)
        XCTAssertEqual(BinderPieceFold.regionCount(cards.count), "1 card")
    }

    func test_aLinkRowGoesToThePiece() {
        let start = WindowSubject(open: .item("ch-1"), faces: .item("ch-1"))
        for incoming in [false, true] {
            let entry = PieceFoldEntry.link(pieceId: "ch-2", title: "Two", incoming: incoming)
            XCTAssertEqual(BinderPieceFold.act(of: entry), .navigate(.item("ch-2")))
            let next = BinderPieceFold.clicked(entry, subject: start, structure: structure,
                                               projectType: .novel)
            XCTAssertEqual(next, ClickRule.navigate(to: .item("ch-2"), current: start,
                                                    structure: structure, projectType: .novel))
            XCTAssertEqual(next.open, .item("ch-2"), "the linked piece opens")
        }
        XCTAssertEqual(BinderPieceFold.linkHelp(incoming: false, piece: "One", other: "Two"),
                       "“One” links to “Two”", "an outgoing row: this piece links there")
        XCTAssertEqual(BinderPieceFold.linkHelp(incoming: true, piece: "One", other: "Two"),
                       "“Two” links to “One”", "an incoming row: the other links here")
        let out = PieceFoldEntry.link(pieceId: "ch-2", title: "Two", incoming: false)
        let into = PieceFoldEntry.link(pieceId: "ch-2", title: "Two", incoming: true)
        XCTAssertTrue(BinderPieceFold.offersRemoveLink(out, mayEditLinks: true))
        XCTAssertFalse(BinderPieceFold.offersRemoveLink(out, mayEditLinks: false), "hidden where refused")
        XCTAssertFalse(BinderPieceFold.offersRemoveLink(into, mayEditLinks: true),
                       "an incoming link is the other piece's to remove")
        // Research is a List tag; a figure is pulled up beside (appraisal 8).
        XCTAssertEqual(BinderPieceFold.act(of: .research(id: "r1", title: "T", owned: true)),
                       .listTag(.research("r1")))
        XCTAssertEqual(BinderPieceFold.act(of: .figure(id: "f1", name: "Map")), .pullUp(.figure("f1")))
        XCTAssertEqual(BinderPieceFold.clicked(.figure(id: "f1", name: "Map"), subject: start,
                                               structure: structure, projectType: .novel).open,
                       start.open, "a fold's figure leaves the centre alone")
        // A double-click opens a palette row in the centre as its research
        // item, and a link is no pull-up row.
        XCTAssertEqual(BinderPieceFold.doubleClicked(.palette(id: "p1", title: "G"), subject: start,
                                                     structure: structure, projectType: .novel,
                                                     photoNode: { _ in nil }),
                       .subject(WindowSubject(open: .research("p1"), faces: .research("p1"))))
        XCTAssertNil(BinderPieceFold.doubleClicked(.link(pieceId: "ch-2", title: "Two", incoming: false),
                                                   subject: start, structure: structure,
                                                   projectType: .novel, photoNode: { _ in nil }))
    }

    /// Tripwire 9 over the fold's file: rows activate through `Button(.plain)`
    /// or a `List` tag, never a tap gesture. The planted control proves the
    /// census reads lines.
    func test_noFoldRowUsesATapGesture() throws {
        let fold = try SourceTree.read("Maugham/Views/BinderPieceFold.swift")
        XCTAssertEqual(Self.tapGestureLines(in: fold), [])
        XCTAssertTrue(fold.contains(".buttonStyle(.plain)"), "rows are plain buttons")
        let planted = fold + "\n        Text(title).onTapGesture { pullUp() }\n"
            + "        Text(title).simultaneousGesture(TapGesture().onEnded { })\n"
        XCTAssertEqual(Self.tapGestureLines(in: planted).count, 2)
    }

    private static func tapGestureLines(in text: String) -> [String] {
        text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }
            .filter { $0.contains(".onTapGesture") || $0.contains("TapGesture(")
                || $0.contains(".simultaneousGesture") }
    }

    /// **Rows look up, never compute** (tripwire 4): no file drawing a fold
    /// derives one. The build is `PieceFoldIndexing`'s `.task`
    /// (`PieceFoldContentsTests.test_theIndexIsBuiltOnlyInATask`).
    func test_noFoldIsComputedPerRow() throws {
        for path in ["Maugham/Views/BinderPieceFold.swift", "Maugham/Views/BinderView.swift",
                     "Maugham/Views/CollectionPiecesPane.swift"] {
            let code = try SourceTree.read(path).components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            for derivation in ["PieceFoldLayout.of(", "PieceFoldIndex.entries(",
                               "TreeSectionDerivation.pieceFold(", "PinnedReferenceResolver."] {
                XCTAssertFalse(code.contains(derivation), "\(path) computes \(derivation)")
            }
        }
    }
}
