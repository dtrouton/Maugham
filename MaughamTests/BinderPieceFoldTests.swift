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

        try expandRow(1, in: outline)

        XCTAssertEqual(outline.numberOfRows, before + 1,
                       "the chapter unfolds to the one item linked to it")
        await select(row: 2, in: outline,
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

        await select(row: 1, in: outline, until: { probe.subject == .item(chapter.id) })
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

        XCTAssertFalse(try isExpandable(row: 1, in: outline),
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

        XCTAssertTrue(try isExpandable(row: 1, in: outline))
    }

    /// **A short story's document never folds**, because everything in Research
    /// already IS that document's — folding it under the row would draw every
    /// note in the project twice.
    func test_aShortStoryDocumentHasNoChevron() async throws {
        let store = try await shortStory()
        _ = try await store.addResearchTextNote(parentId: nil, title: "Tides")

        let (window, _) = try await hostBinder(store: store)
        let outline = try XCTUnwrap(outlineView(in: window))

        XCTAssertFalse(try isExpandable(row: 1, in: outline))
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

        XCTAssertFalse(try isExpandable(row: 1, in: outline),
                       "the script row is the screenplay's one document and it "
                       + "folds onto nothing")
    }

    // MARK: - The collection piece's fold (contained)

    func test_aCollectionPieceUnfoldsToTheResearchInItsOwnFolder() async throws {
        let store = try await collection()
        let piece = try await store.addLoosePiece(title: "Alpha", mode: .prose)
        let owned = try await store.addPieceResearchNote(
            pieceId: piece.id, title: "Alpha's Note")
        _ = try await store.addResearchTextNote(parentId: nil, title: "Shared Note")

        let (window, probe) = try await hostCollection(store: store)
        let outline = try XCTUnwrap(outlineView(in: window))
        let before = outline.numberOfRows

        try expandRow(1, in: outline)

        XCTAssertEqual(outline.numberOfRows, before + 1,
                       "the piece unfolds to what is in its own research "
                       + "folder — and not to the shared note beside it")
        await select(row: 2, in: outline,
                     until: { probe.subject == .research(owned.id) })
        XCTAssertEqual(probe.subject, .research(owned.id))
    }

    func test_aCollectionPieceWithNoResearchOfItsOwnHasNoChevron() async throws {
        let store = try await collection()
        _ = try await store.addLoosePiece(title: "Alpha", mode: .prose)
        _ = try await store.addResearchTextNote(parentId: nil, title: "Shared Note")

        let (window, _) = try await hostCollection(store: store)
        let outline = try XCTUnwrap(outlineView(in: window))

        XCTAssertFalse(try isExpandable(row: 1, in: outline),
                       "the project's shared research is not this piece's")
    }

    func test_aFoldedPieceRowIsStillThePiecesOwnSubject() async throws {
        let store = try await collection()
        let piece = try await store.addLoosePiece(title: "Alpha", mode: .prose)
        _ = try await store.addPieceResearchNote(pieceId: piece.id, title: "Alpha's Note")

        let (window, probe) = try await hostCollection(store: store)
        let outline = try XCTUnwrap(outlineView(in: window))

        await select(row: 1, in: outline, until: { probe.subject == .item(piece.id) })
        XCTAssertEqual(probe.subject, .item(piece.id))
    }

    /// **Containment is a tree, so a group inside a piece expands.** This is
    /// the one place the two fold semantics visibly differ: a group in a
    /// piece's own folder holds that piece's research, so it keeps its
    /// disclosure triangle, where a novel chapter's fold is flat.
    func test_aGroupInsideACollectionPiecesFoldExpandsToItsChildren() async throws {
        let store = try await collection()
        let piece = try await store.addLoosePiece(title: "Alpha", mode: .prose)
        let group = try await store.addResearchItem(
            parentId: nil, title: "Sources", kind: nil)
        let child = try await store.addResearchTextNote(
            parentId: group.id, title: "A Clipping")
        try await store.moveResearchItems(ids: [group.id], to: .piece(piece.id))

        let (window, probe) = try await hostCollection(store: store)
        let outline = try XCTUnwrap(outlineView(in: window))

        try expandRow(1, in: outline)   // the piece
        XCTAssertTrue(try isExpandable(row: 2, in: outline),
                      "the group inside the piece keeps its own triangle")
        try expandRow(2, in: outline)   // the group

        await select(row: 3, in: outline, until: { probe.subject == .research(child.id) })
        XCTAssertEqual(probe.subject, .research(child.id),
                       "and its child is a subject like any other row")
    }

    /// **A linked group in a novel chapter's fold does NOT expand.** The fold's
    /// rows are the chapter's `linkedResearchIds`, resolved; a group's children
    /// are not linked to that chapter by anything, so showing them under it
    /// would claim a link nothing recorded.
    func test_aLinkedGroupInANovelChaptersFoldStaysFlat() async throws {
        let store = try await novel()
        let chapter = try XCTUnwrap(store.manifest.structure.first)
        let group = try await store.addResearchItem(
            parentId: nil, title: "Sources", kind: nil)
        _ = try await store.addResearchTextNote(parentId: group.id, title: "A Clipping")
        try await store.linkResearch(researchId: group.id, toDocumentId: chapter.id)

        let (window, _) = try await hostBinder(store: store)
        let outline = try XCTUnwrap(outlineView(in: window))

        try expandRow(1, in: outline)
        XCTAssertFalse(try isExpandable(row: 2, in: outline),
                       "the group is in the fold because it is linked; its "
                       + "children are not, and the fold must not say they are")
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
        let piece = try await store.addLoosePiece(title: "Alpha", mode: .prose)
        _ = try await store.addPieceResearchNote(pieceId: piece.id, title: "Alpha's Note")

        let state = BinderTreeSectionsState()
        let (window, _) = try await hostCollection(store: store, state: state)
        let outline = try XCTUnwrap(outlineView(in: window))

        try expandRow(1, in: outline)
        XCTAssertEqual(state.expandedPieceFolds, [piece.id],
                       "the click the writer makes is what the window reads")

        try collapseRow(1, in: outline)
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
        let piece = try await store.addLoosePiece(title: "Alpha", mode: .prose)
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
                                 projectType: store.manifest.type)
        XCTAssertEqual(shown, .item(piece.id))
        _ = await pumpUntil(deadline: 5) { outline.numberOfRows > before }

        XCTAssertEqual(outline.numberOfRows, before + 1,
                       "the fold opened and its row is drawn")
        await select(row: 2, in: outline,
                     until: { probe.subject == .research(owned.id) })
        XCTAssertEqual(probe.subject, .research(owned.id),
                       "and the row on screen is the note the reveal named")
    }

    /// **The scroll half of the case above** (stage-3b Task 8). Existence was
    /// the whole of the old contract; arrival is visible now, not just true —
    /// with the piece pushed far enough down the tree that its row starts
    /// off-screen, the reveal's own scroll request has to bring it back.
    ///
    /// **The PIECE row, not the note's** — `reveal`'s own answer for a
    /// piece-scoped id (a closed fold has no row of its own to scroll to yet;
    /// Task 7's report records the choice).
    func test_aRevealOfAPieceScopedNotePutsThePieceRowOnScreen() async throws {
        let store = try await collection()
        for i in 0..<60 {
            _ = try await store.addLoosePiece(title: "Filler \(i)", mode: .prose)
        }
        let piece = try await store.addLoosePiece(title: "Alpha", mode: .prose)
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
                                 projectType: store.manifest.type)
        state.scrollRequest = shown.map(TreeScrollTarget.row)
        await pumpUntil(deadline: 5) { self.isRowVisible(pieceRow, in: outline) }

        XCTAssertTrue(isRowVisible(pieceRow, in: outline),
                      "the reveal opened the fold but did not scroll the "
                      + "piece's own row onto screen")
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
        let piece = try await store.addLoosePiece(title: "Alpha", mode: .prose)
        let owned = try await store.addPieceResearchNote(
            pieceId: piece.id, title: "Alpha's Note")

        let (window, probe) = try await hostCollection(store: store, sweeping: true)
        let outline = try XCTUnwrap(outlineView(in: window))
        try expandRow(1, in: outline)
        await select(row: 2, in: outline, until: { probe.subject == .research(owned.id) })
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
        let piece = try await store.addLoosePiece(title: "Alpha", mode: .prose)
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
        let piece = try await store.addLoosePiece(title: "Alpha", mode: .prose)
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

    /// **A linked note is drawn TWICE in one `List`** — once in the shared
    /// Research section, where it lives, and once in the fold of every chapter
    /// that links it — and both rows read the same `renamingItemId`. So Rename
    /// used to mount two `TextField`s in one list, each running tripwire 16's
    /// 30ms `claimFocus()` deferral against the other: the writer's typing goes
    /// to whichever won, and the other field sits over the row it names.
    ///
    /// The fix is that a `.linked` fold is a VIEW of the chapter's links and
    /// offers no rename of its own. The note is renamed where it lives.
    func test_renamingALinkedNoteOpensExactlyOneFieldInTheWholeTree() async throws {
        let store = try await novel()
        let chapter = try XCTUnwrap(store.manifest.structure.first)
        let note = try await store.addResearchTextNote(parentId: nil, title: "Tides")
        try await store.linkResearch(researchId: note.id, toDocumentId: chapter.id)

        let state = BinderTreeSectionsState()
        let (window, probe) = try await hostFoldAndSections(store: store, state: state,
                                                            documentId: chapter.id)
        let outline = try XCTUnwrap(outlineView(in: window))
        let before = outline.numberOfRows
        try expandRow(0, in: outline)
        XCTAssertEqual(outline.numberOfRows, before + 1,
                       "precondition: the chapter's fold draws the linked note")

        // **The two rows, named by what they select.** SwiftUI draws a row's
        // label into a hosting view rather than an `NSTextField`, so a row is
        // identified here the way every test in this file identifies one: by the
        // subject it writes. Row 1 is inside the fold, row 3 is in the shared
        // Research section, and both are this note.
        for row in [1, 3] {
            probe.subject = .project
            await select(row: row, in: outline,
                         until: { probe.subject == .research(note.id) })
            XCTAssertEqual(probe.subject, .research(note.id),
                           "precondition: row \(row) is the note — it is drawn "
                           + "in the chapter's fold AND in the shared section")
        }

        state.renamingItemId = note.id
        pump(0.3)

        XCTAssertEqual(
            renameFields(in: window, titled: note.title).count, 1,
            "one rename request must open one field. Two fields in one list "
            + "race for focus (tripwire 16) and the writer types into whichever "
            + "won, over a row that is not the one they asked to rename")
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
            outline.numberOfRows, 8,
            "precondition — the chapter row, its fold's TWO linked notes, the "
            + "Research header and the same two notes under it, then the "
            + "Palette header and its placeholder. The note the writer just "
            + "made is in the fold they asked from and in the shared section it "
            + "lives in")
        XCTAssertEqual(
            renameFields(in: window, titled: "Untitled Note").count, 1,
            "creating a note opens ONE rename field — the shared section's")
    }

    /// **The control: a contained fold keeps the verb.** A Collection piece's
    /// research lives in that piece's own folder and is drawn exactly once, so
    /// there is no twin to race with and nothing to take away. Without this,
    /// removing rename from every fold would pass the two tests above.
    func test_aNoteInACollectionPiecesFoldStillRenamesInPlace() async throws {
        let store = try await collection()
        let piece = try await store.addLoosePiece(title: "Alpha", mode: .prose)
        let owned = try await store.addPieceResearchNote(
            pieceId: piece.id, title: "Alpha's Note")

        let state = BinderTreeSectionsState()
        let (window, _) = try await hostFoldAndSections(store: store, state: state,
                                                        documentId: piece.id)
        let outline = try XCTUnwrap(outlineView(in: window))
        try expandRow(0, in: outline)
        XCTAssertEqual(
            outline.numberOfRows, 6,
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
            node.contains("if offersRename {"),
            "the Rename button must be behind `offersRename` — the field and the "
            + "menu item are one decision, and a menu that offers what the row "
            + "cannot do is worse than no menu")
        XCTAssertTrue(
            node.contains("offersRename ? $renamingItemId : .constant(nil)"),
            "…and the row's binding must be dead where it does not offer "
            + "rename, or `pendingRenameId` opens the field the menu no longer "
            + "can")

        let foldSource = try source(of: "Maugham/Views/BinderPieceFold.swift")
        XCTAssertTrue(
            foldSource.contains("offersRename: fold.semantic == .contained"),
            "a fold offers rename exactly where its rows are drawn once")
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
        let window = try source(of: "Maugham/Views/ProjectWindow.swift")
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
        BinderPieceFold(
            store: store,
            state: state ?? BinderTreeSectionsState(),
            selectedSubject: .constant(nil),
            documentId: documentId,
            fold: TreeSectionDerivation.pieceFold(
                forDocumentId: documentId,
                structure: store.manifest.structure,
                research: store.manifest.research,
                projectType: store.manifest.type))
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
        let frame = CGRect(x: 0, y: 0, width: 320, height: 800)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = frame
        let window = SilentTestWindow(contentRect: frame, styleMask: [.titled],
                                      backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        windows.append(window)
        await pumpUntil(deadline: 5) { self.outlineView(in: window) != nil }
        // The palette section loads its cards from disk once per manifest
        // change, so the rows it contributes arrive a turn after the list does.
        pump(0.2)
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
        BinderView(store: store,
                   selectedSubject: Binding(get: { probe.subject },
                                            set: { probe.subject = $0 }),
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
        CollectionPiecesPane(store: store, selectedSubject: subject,
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
        let subject = Binding(get: { probe.subject }, set: { probe.subject = $0 })
        // The hosts' own binding — a SET since stage-2b Task 3, over the same
        // state this probe already hands the fold and the sections.
        List(selection: BinderTreeSelection.binding(
                subject: subject, state: state, store: store)) {
            DisclosureGroup {
                BinderPieceFold(
                    store: store, state: state, selectedSubject: subject,
                    documentId: documentId,
                    // Derived per render from the manifest, as the hosts do —
                    // a fold captured once would not show the note a test just
                    // asked the store to make.
                    fold: TreeSectionDerivation.pieceFold(
                        forDocumentId: documentId,
                        structure: store.manifest.structure,
                        research: store.manifest.research,
                        projectType: store.manifest.type))
            } label: {
                Text(TreeWalk.find(id: documentId, in: store.manifest.structure)?.title
                     ?? documentId)
            }
            .tag(BinderSubject.item(documentId))
            BinderTreeSections(store: store, state: state, selectedSubject: subject)
        }
        .listStyle(.sidebar)
        .binderTreeSections(store: store, state: state, selectedSubject: subject)
    }
}

@MainActor
private struct FoldNavigatorProbeView: View {
    let store: ProjectStore
    let probe: BinderSubjectProbe
    let documentID: String?
    let treeState = BinderTreeSectionsState()

    var body: some View {
        SceneNavigatorPane(
            store: store,
            script: FountainTokenizer().parse("INT. KITCHEN - DAY\n\nLarry sits.\n"),
            projectTitle: store.manifest.title,
            selectedSubject: Binding(get: { probe.subject },
                                     set: { probe.subject = $0 }),
            documentID: documentID,
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
            store: store, selectedSubject: $selectedSubject))
    }
}

