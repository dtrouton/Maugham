import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **A drag across the binder tree, all the way to the manifest**
/// (shell-finish stage-2a Task 7).
///
/// `TreeDropIntentTests` says what each drop MEANS, over manifest values and
/// nothing else. This file says the meaning is carried out: the verbs the rows
/// call are asked on a real `ProjectStore`, and what is asserted afterwards is
/// the project on disk — a link that appeared, a file that moved between
/// `research/` and `pieces/<slug>/research/`, an order that changed.
///
/// **Why the verbs and not a drag.** A real drag session is not synthesisable
/// headless — nothing can drive the closure a `.dropDestination` installs — so
/// the production value the row's closure calls is as close to the writer's
/// gesture as a test can get. That the closures actually CALL it is a separate
/// question, held by `TripwireGrepTests.test_everyDropTargetInTheTreeReachesTheClassifier`.
@MainActor
final class BinderTreeDropRoutingTests: XCTestCase {

    private var temp: TempDirectory!
    private var windows: [NSWindow] = []
    private var documentStores: [DocumentStore] = []
    private var states: [ObjectIdentifier: BinderTreeSectionsState] = [:]

    override func setUp() async throws {
        temp = TempDirectory()
    }

    override func tearDown() async throws {
        for window in windows { window.contentView = NSView(frame: .zero) }
        pump(0.05)
        windows.removeAll()
        for ds in documentStores { await ds.close() }
        documentStores.removeAll()
        states.removeAll()
        temp.cleanup()
        temp = nil
    }

    // MARK: - A novel: the chapter row links

    func test_aNoteDroppedOnAChapterBecomesThatChaptersResearch() async throws {
        let store = try await novel(notes: ["Ships"])
        let note = try XCTUnwrap(research(named: "Ships", in: store))
        let chapter = try XCTUnwrap(store.manifest.structure.first)

        let accepted = verbs(store).routePieceRowDrop(
            draggedId: note.id, documentId: chapter.id,
            structureReorder: { XCTFail("a research id is not a manuscript reorder") })

        XCTAssertTrue(accepted, "the chapter can take it, so the drag lands")
        await settle(store) { !store.linkedResearchIds(forDocumentId: chapter.id).isEmpty }
        XCTAssertEqual(store.linkedResearchIds(forDocumentId: chapter.id), [note.id],
                       "a novel chapter's research is a LINK — the note has not "
                       + "moved anywhere, it now belongs to this chapter too")
    }

    func test_theSameNoteDraggedToTheResearchSectionLeavesTheChapter() async throws {
        let store = try await novel(notes: ["Ships"])
        let note = try XCTUnwrap(research(named: "Ships", in: store))
        let chapter = try XCTUnwrap(store.manifest.structure.first)
        try await store.linkResearch(researchId: note.id, toDocumentId: chapter.id)

        let accepted = verbs(store).routeSharedSectionDrop(draggedId: note.id)

        XCTAssertTrue(accepted)
        await settle(store) { store.linkedResearchIds(forDocumentId: chapter.id).isEmpty }
        XCTAssertEqual(store.linkedResearchIds(forDocumentId: chapter.id), [],
                       "out of the fold, out of the link — the drag is how a "
                       + "writer says this is the project's, not the chapter's")
        XCTAssertNotNil(research(named: "Ships", in: store),
                        "and the note itself is untouched: unlinking is not "
                        + "deleting, and shared research still holds it")
    }

    func test_aNoteDroppedInsideAChaptersFoldLinksToThatChapter() async throws {
        let store = try await novel(notes: ["Ships", "Tides"])
        let ships = try XCTUnwrap(research(named: "Ships", in: store))
        let tides = try XCTUnwrap(research(named: "Tides", in: store))
        let chapter = try XCTUnwrap(store.manifest.structure.first)
        try await store.linkResearch(researchId: tides.id, toDocumentId: chapter.id)
        let fold = TreeSectionDerivation.pieceFold(
            forDocumentId: chapter.id, structure: store.manifest.structure,
            research: store.manifest.research, projectType: store.manifest.type)

        // The fold's own bundle — the one difference from the section's is the
        // document it carries, and this is the assertion that it carries it.
        let actions = BinderPieceFold(
            store: store, state: BinderTreeSectionsState(),
            selectedSubject: .constant(nil),
            documentId: chapter.id, fold: fold).actions
        let accepted = actions.internalDrop(ships.id, .middle, tides)

        XCTAssertTrue(accepted)
        await settle(store) {
            store.linkedResearchIds(forDocumentId: chapter.id).count == 2
        }
        XCTAssertEqual(
            Set(store.linkedResearchIds(forDocumentId: chapter.id)),
            [ships.id, tides.id],
            "a fold row is a near-miss of the piece row above it and means the "
            + "same thing. Without the fold's re-route this would have been "
            + "read as an ordinary research row and quietly REORDERED shared "
            + "research instead — with nothing on screen to say so")
    }

    /// The control: the same drop on a row of the SHARED section, where there
    /// is no document, is the ordinary reorder and links nothing.
    func test_control_theSameDropOnTheSharedSectionsRowsLinksNothing() async throws {
        let store = try await novel(notes: ["Ships", "Tides"])
        let ships = try XCTUnwrap(research(named: "Ships", in: store))
        let tides = try XCTUnwrap(research(named: "Tides", in: store))
        let chapter = try XCTUnwrap(store.manifest.structure.first)
        let sections = BinderTreeSections(
            store: store, state: BinderTreeSectionsState(),
            selectedSubject: .constant(nil))

        XCTAssertTrue(sections.actions.internalDrop(ships.id, .top, tides))

        await settle(store) {
            store.manifest.research.filter { $0.role == nil }.first?.title == "Ships"
        }
        XCTAssertEqual(store.linkedResearchIds(forDocumentId: chapter.id), [],
                       "control: the section's rows carry no document, so the "
                       + "same gesture is a reorder — which is what makes the "
                       + "fold assertion above about the re-route")
        XCTAssertEqual(
            store.manifest.research.filter { $0.role == nil }.map(\.title),
            ["Ships", "Tides"],
            "…and the reorder happened: Ships moved above Tides")
    }

    // MARK: - A collection: the piece row moves the file

    func test_aNoteDroppedOnALoosePieceMovesIntoThatPiecesFolder() async throws {
        let store = try await collection(pieces: ["One"], notes: ["Ships"])
        let note = try XCTUnwrap(research(named: "Ships", in: store))
        let piece = try XCTUnwrap(store.manifest.structure.first)
        XCTAssertEqual(note.path, "research/ships.md", "fixture precondition")

        let accepted = verbs(store).routePieceRowDrop(
            draggedId: note.id, documentId: piece.id,
            structureReorder: { XCTFail("a research id is not a piece reorder") })

        XCTAssertTrue(accepted)
        await settle(store) {
            self.research(named: "Ships", in: store)?.path?.hasPrefix("pieces/") == true
        }
        let moved = try XCTUnwrap(research(named: "Ships", in: store))
        XCTAssertEqual(moved.path?.hasPrefix("pieces/"), true,
                       "a Collection piece's research is CONTAINMENT — the file "
                       + "itself moves, and the tree hands that to the typed "
                       + "mover rather than moving anything itself. Got "
                       + "\(moved.path ?? "nil")")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: store.url.appendingPathComponent(moved.path ?? "").path),
            "and the file is where the manifest says it is")
    }

    func test_thePiecesOwnNoteDraggedToTheResearchSectionComesBackOut() async throws {
        let store = try await collection(pieces: ["One"], notes: [])
        let piece = try XCTUnwrap(store.manifest.structure.first)
        let note = try await store.createResearchNote(
            scope: .document(piece.id), title: "Ships")

        XCTAssertTrue(verbs(store).routeSharedSectionDrop(draggedId: note.id))

        await settle(store) {
            self.research(named: "Ships", in: store)?.path?.hasPrefix("pieces/") == false
        }
        let moved = try XCTUnwrap(research(named: "Ships", in: store))
        XCTAssertEqual(moved.path?.hasPrefix("pieces/"), false,
                       "the section IS the shared root. Got \(moved.path ?? "nil")")
    }

    /// **A scope move leaves the links alone** — the dormant-link semantics
    /// (`ProjectStore+ResearchMove`), asserted through the drag rather than
    /// through the store, because the drag is the new caller.
    ///
    /// A link on a Collection piece is dormant data: the Collection's own scope
    /// is its folder, so nothing in the app reads it — but it is reachable
    /// (`link_research` over MCP, a project that was another type once), and a
    /// drag that silently deleted it would be destroying something the writer
    /// cannot see and did not point at. Both halves are pinned: the move keeps
    /// the link, and a drop on the shared section reads the piece's scope
    /// rather than the dormant link.
    func test_aDragThatChangesScopeDoesNotSilentlyUnlink() async throws {
        let store = try await collection(pieces: ["One", "Two"], notes: ["Ships"])
        let note = try XCTUnwrap(research(named: "Ships", in: store))
        let one = try XCTUnwrap(store.manifest.structure.first)
        let two = try XCTUnwrap(store.manifest.structure.last)
        try await store.linkResearch(researchId: note.id, toDocumentId: one.id)

        XCTAssertTrue(verbs(store).routePieceRowDrop(
            draggedId: note.id, documentId: two.id, structureReorder: {}))
        await settle(store) {
            self.research(named: "Ships", in: store)?.path?.contains("/research/") == true
        }

        XCTAssertEqual(store.linkedResearchIds(forDocumentId: one.id), [note.id],
                       "the scope move rewrote the note's path and left every "
                       + "link exactly as it found it")
        let moved = try XCTUnwrap(research(named: "Ships", in: store))
        XCTAssertEqual(moved.path?.contains("/research/"), true,
                       "…and the move did happen. Got \(moved.path ?? "nil")")

        // The second half: with a dormant link present, the shared section is
        // still a SCOPE move and not an unlink.
        XCTAssertTrue(verbs(store).routeSharedSectionDrop(draggedId: note.id))
        await settle(store) {
            self.research(named: "Ships", in: store)?.path?.hasPrefix("pieces/") == false
        }
        XCTAssertEqual(store.linkedResearchIds(forDocumentId: one.id), [note.id],
                       "a Collection piece's routing does not use links, so a "
                       + "link on one must never be what a drop on the shared "
                       + "section answers")
    }

    func test_aReferencedPieceRefusesTheDropRatherThanSwallowingIt() async throws {
        let store = try await collection(pieces: ["One"], notes: ["Ships"])
        let note = try XCTUnwrap(research(named: "Ships", in: store))
        let reference = try await linkedReferencePiece(in: store)
        let before = store.manifest.research

        let accepted = verbs(store).routePieceRowDrop(
            draggedId: note.id, documentId: reference.id, structureReorder: {})

        XCTAssertFalse(accepted,
                       "a referenced piece keeps its research in its own "
                       + "project — the drag must bounce back to where the "
                       + "writer took it from, not animate home and vanish")
        await settle(store)
        XCTAssertEqual(store.manifest.research, before, "and nothing moved")
    }

    // MARK: - The single-document types have no scope to change

    func test_aScreenplaysScriptRowRefusesAResearchDrop() async throws {
        let store = try await screenplay(notes: ["Ships"])
        let note = try XCTUnwrap(research(named: "Ships", in: store))
        let script = try XCTUnwrap(TreeWalk.first(
            in: store.manifest.structure, where: { $0.type == .document }))

        XCTAssertFalse(
            verbs(store).routePieceRowDrop(
                draggedId: note.id, documentId: script.id, structureReorder: {}),
            "everything in a screenplay's research is already the script's, so "
            + "there is nothing for the drop to change and it says so")
    }

    // MARK: - Ids the tree cannot place

    func test_anIdFromSomewhereElseIsRefusedAtEveryTarget() async throws {
        let store = try await novel(notes: ["Ships"])
        let note = try XCTUnwrap(research(named: "Ships", in: store))
        let chapter = try XCTUnwrap(store.manifest.structure.first)
        let sections = BinderTreeSections(
            store: store, state: BinderTreeSectionsState(),
            selectedSubject: .constant(nil))

        XCTAssertFalse(verbs(store).routePieceRowDrop(
            draggedId: "canvas-node-1", documentId: chapter.id,
            structureReorder: { XCTFail("an unknown id is not a reorder") }))
        XCTAssertFalse(sections.actions.internalDrop("canvas-node-1", .middle, note))
        XCTAssertFalse(sections.sharedSectionDrop(["canvas-node-1"]))
    }

    // MARK: - A file from Finder, all the way to the folder (stage-2b Task 4)

    /// **The capability the dying panes carried, on the tree's own targets.**
    ///
    /// These go through `NSItemProvider`s built from real files, so the whole
    /// path is exercised — `DropClassification`'s classification, the store
    /// verb the destination names, and the file that has to end up somewhere a
    /// writer can find. A drop that imports to the wrong scope does not lose a
    /// row: it files the writer's photograph where they never pointed.

    func test_aFileDroppedOnTheResearchSectionLandsInSharedResearch() async throws {
        let store = try await novel(notes: [])
        let file = try makeFile(named: "harbour.md", contents: "# Harbour")

        let accepted = verbs(store).routeExternalDrop(
            providers: [provider(for: file)], position: .middle,
            target: .sharedSection)

        XCTAssertTrue(accepted)
        await settle(store) { self.research(named: "harbour", in: store) != nil }
        let imported = try XCTUnwrap(research(named: "harbour", in: store))
        XCTAssertEqual(imported.path, "research/harbour.md",
                       "the section IS the shared root. Got \(imported.path ?? "nil")")
    }

    func test_aFileDroppedOnANovelChapterIsImportedAndLinkedInOneAct() async throws {
        let store = try await novel(notes: [])
        let chapter = try XCTUnwrap(store.manifest.structure.first)
        let file = try makeFile(named: "tides.md", contents: "# Tides")

        XCTAssertTrue(verbs(store).routeExternalDrop(
            providers: [provider(for: file)], position: .middle,
            target: .pieceRow(chapter.id)))

        await settle(store) {
            !store.linkedResearchIds(forDocumentId: chapter.id).isEmpty
        }
        let imported = try XCTUnwrap(research(named: "tides", in: store))
        XCTAssertEqual(imported.path, "research/tides.md",
                       "a novel chapter has no research folder of its own, so "
                       + "the file lands in shared research")
        XCTAssertEqual(store.linkedResearchIds(forDocumentId: chapter.id),
                       [imported.id],
                       "…and the link is the other half of the same act. "
                       + "Importing without linking leaves the writer's file in "
                       + "the section they did not aim at")
    }

    func test_aFileDroppedOnACollectionPieceLandsInThatPiecesFolder() async throws {
        let store = try await collection(pieces: ["One"], notes: [])
        let piece = try XCTUnwrap(store.manifest.structure.first)
        let file = try makeFile(named: "map.md", contents: "# Map")

        XCTAssertTrue(verbs(store).routeExternalDrop(
            providers: [provider(for: file)], position: .middle,
            target: .pieceRow(piece.id)))

        await settle(store) { self.research(named: "map", in: store) != nil }
        let imported = try XCTUnwrap(research(named: "map", in: store))
        XCTAssertEqual(imported.path?.hasPrefix("pieces/"), true,
                       "a Collection piece's research is containment — this is "
                       + "`importPieceResearchFiles`, whose only caller before "
                       + "this task was the pane the milestone deletes. Got "
                       + "\(imported.path ?? "nil")")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: store.url.appendingPathComponent(imported.path ?? "").path),
            "and the file is where the manifest says it is")
    }

    /// **The fold's external drop carries the fold's own document**, which is
    /// the same re-route its internal drop needed and fails the same silent
    /// way: without it the row reads as an ordinary shared research row and the
    /// writer's file lands in shared research, unlinked, with nothing on screen
    /// to say the chapter never got it.
    func test_aFileDroppedInsideAChaptersFoldReachesThatChapter() async throws {
        let store = try await novel(notes: ["Ships"])
        let ships = try XCTUnwrap(research(named: "Ships", in: store))
        let chapter = try XCTUnwrap(store.manifest.structure.first)
        try await store.linkResearch(researchId: ships.id, toDocumentId: chapter.id)
        let fold = TreeSectionDerivation.pieceFold(
            forDocumentId: chapter.id, structure: store.manifest.structure,
            research: store.manifest.research, projectType: store.manifest.type)
        let file = try makeFile(named: "charts.md", contents: "# Charts")

        let actions = BinderPieceFold(
            store: store, state: state(for: store),
            selectedSubject: .constant(nil),
            documentId: chapter.id, fold: fold).actions
        XCTAssertTrue(actions.externalDrop([provider(for: file)], .bottom, ships))

        await settle(store) {
            store.linkedResearchIds(forDocumentId: chapter.id).count == 2
        }
        let imported = try XCTUnwrap(research(named: "charts", in: store))
        XCTAssertTrue(
            store.linkedResearchIds(forDocumentId: chapter.id).contains(imported.id),
            "a file dropped in chapter one's fold is chapter one's")
    }

    /// The control for the fold: the SAME drop on a row of the shared section,
    /// where there is no document, imports and links nothing.
    func test_control_theSameFileDroppedOnASharedRowLinksNothing() async throws {
        let store = try await novel(notes: ["Ships"])
        let ships = try XCTUnwrap(research(named: "Ships", in: store))
        let chapter = try XCTUnwrap(store.manifest.structure.first)
        let sections = BinderTreeSections(
            store: store, state: state(for: store), selectedSubject: .constant(nil))
        let file = try makeFile(named: "charts.md", contents: "# Charts")

        XCTAssertTrue(sections.actions.externalDrop(
            [provider(for: file)], .bottom, ships))

        await settle(store) { self.research(named: "charts", in: store) != nil }
        XCTAssertEqual(store.linkedResearchIds(forDocumentId: chapter.id), [],
                       "control: the section's rows carry no document, so the "
                       + "same gesture is a plain import — which is what makes "
                       + "the fold assertion above about the re-route")
    }

    func test_aFileDroppedIntoAGroupRowLandsInsideThatGroup() async throws {
        let store = try await novel(notes: [])
        let group = try await store.addResearchItem(
            parentId: nil, title: "World", kind: nil)
        let sections = BinderTreeSections(
            store: store, state: state(for: store), selectedSubject: .constant(nil))
        let file = try makeFile(named: "maps.md", contents: "# Maps")

        XCTAssertTrue(sections.actions.externalDrop(
            [provider(for: file)], .middle, group))

        await settle(store) { self.research(named: "maps", in: store) != nil }
        let imported = try XCTUnwrap(research(named: "maps", in: store))
        XCTAssertEqual(imported.path, "research/world/maps.md",
                       "dropped ON a group is INTO it — the same gesture that "
                       + "moves a note into one. Got \(imported.path ?? "nil")")
    }

    func test_aScreenplaysScriptRowBouncesAFileAndImportsNothing() async throws {
        let store = try await screenplay(notes: [])
        let script = try XCTUnwrap(TreeWalk.first(
            in: store.manifest.structure, where: { $0.type == .document }))
        let file = try makeFile(named: "notes.md", contents: "# Notes")
        let before = store.manifest.research

        XCTAssertFalse(
            verbs(store).routeExternalDrop(
                providers: [provider(for: file)], position: .middle,
                target: .pieceRow(script.id)),
            "everything in a screenplay's research is already the script's, so "
            + "there is no scope the drop is asking for — and a refusal the "
            + "writer can see beats a file quietly appearing elsewhere")
        await settle(store)
        XCTAssertEqual(store.manifest.research, before, "and nothing imported")
    }

    // MARK: - ⌘V (stage-2b Task 4)

    /// The paste table `ResearchView` owned, on its new host. A pasted URL is a
    /// research link; a pasted image or file is an asset; pasted text is a
    /// note. All in shared research, which is what the pane did.
    func test_aPastedURLBecomesALinkInSharedResearch() async throws {
        let store = try await novel(notes: [])
        let importer = ResearchPasteImporter(store: store, reportError: { _ in })

        await importer.paste([NSItemProvider(
            object: URL(string: "https://example.com/tides")! as NSURL)])

        // The provider answers `loadItem` with the URL's BYTES rather than a
        // `URL` — measured, and the reason the moved table needed its one
        // change: `ResearchView` cast to `URL` alone, so this paste fell
        // through every arm and did nothing, silently. See
        // `ResearchPasteImporter.url(from:)`.
        let link = try XCTUnwrap(
            store.manifest.research.first { $0.kind == .link },
            "a pasted URL is a link, titled by its host")
        XCTAssertEqual(link.url, "https://example.com/tides")
        XCTAssertEqual(link.title, "example.com")
    }

    func test_pastedTextBecomesANoteInSharedResearch() async throws {
        let store = try await novel(notes: [])
        let importer = ResearchPasteImporter(store: store, reportError: { _ in })
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: "public.text", visibility: .all) { completion in
                completion(Data("The tide was out.".utf8), nil)
                return nil
            }

        await importer.paste([provider])

        let note = try XCTUnwrap(
            store.manifest.research.first { $0.role == nil && $0.kind == .document },
            "pasted text lands as a research document")
        let path = try XCTUnwrap(note.path)
        XCTAssertEqual(
            try String(contentsOf: store.url.appendingPathComponent(path),
                       encoding: .utf8),
            "The tide was out.",
            "…carrying the words that were pasted")
    }

    /// **Which window states a paste belongs to research at all.** The tree is
    /// one `List` holding manuscript rows as well as research ones, so a ⌘V
    /// with a chapter selected is not research's to take.
    func test_aPasteBelongsToResearchOnlyWhenTheWindowIsAboutResearchOrTheProject() {
        XCTAssertTrue(TreePasteRouting.acceptsPaste(subject: .research("res-1")))
        XCTAssertTrue(TreePasteRouting.acceptsPaste(subject: .project))
        XCTAssertFalse(TreePasteRouting.acceptsPaste(subject: .item("ch1")),
                       "a chapter is selected: the writer's ⌘V is about the "
                       + "manuscript, and a research note appearing instead is "
                       + "a surprise the old pane could never have produced")
        XCTAssertFalse(TreePasteRouting.acceptsPaste(subject: nil))
    }

    // MARK: - Add File… (stage-2b Task 4)

    /// **The panel takes folders again.** `ResearchView`'s always has —
    /// `importResearchFiles` imports a folder as a group with its contents
    /// under it — and stage 2a's tree narrowed it to files without saying so.
    /// The pane is about to be deleted, so the narrowing would have shipped as
    /// a lost capability.
    func test_theTreesAddFilePanelTakesFoldersAsWellAsFiles() {
        let panel = BinderTreeVerbs.makeAddFilePanel()
        XCTAssertTrue(panel.canChooseDirectories,
                      "a folder imports as a group of its contents — the tree "
                      + "is the only surface left that can ask for one")
        XCTAssertTrue(panel.canChooseFiles)
        XCTAssertTrue(panel.allowsMultipleSelection)
    }

    // MARK: - The subject survives its own rescope

    /// **The window keeps pointing at the note the writer just moved**
    /// (Task 2's fingerprint blindness, through the drop path).
    ///
    /// A scope move rewrites the item's path and — in a Collection — takes it
    /// out of the tree's Research section and into the piece's fold, which is
    /// exactly the kind of manifest change that a subject sweep watching the
    /// wrong thing would read as "the subject is gone". It is not gone: it is
    /// the same id, one folder over, and the writer is still looking at it.
    ///
    /// Mounted, because the sweep runs on the window and not on the store. The
    /// drag itself is not synthesisable, so the drop is driven through the
    /// production verb while the tree is on screen.
    func test_theSubjectSurvivesItsOwnRescope() async throws {
        let store = try await collection(pieces: ["One"], notes: ["Ships"])
        let note = try XCTUnwrap(research(named: "Ships", in: store))
        let piece = try XCTUnwrap(store.manifest.structure.first)
        let probe = BinderSubjectProbe(.research(note.id))
        _ = try await mountCollection(store: store, probe: probe)

        XCTAssertTrue(verbs(store).routePieceRowDrop(
            draggedId: note.id, documentId: piece.id, structureReorder: {}))
        await settle(store) {
            self.research(named: "Ships", in: store)?.path?.hasPrefix("pieces/") == true
        }
        pump(0.3)

        XCTAssertEqual(probe.subject, .research(note.id),
                       "the note moved scope; it did not stop existing, and the "
                       + "window must still be about it")
        let moved = try XCTUnwrap(research(named: "Ships", in: store))
        XCTAssertEqual(moved.path?.hasPrefix("pieces/"), true,
                       "precondition for the assertion above: the move DID "
                       + "happen. Got \(moved.path ?? "nil")")
    }

    /// The control, and the test above says nothing without it: the sweep it
    /// survives has to be a sweep that WOULD have fired. Delete the same note
    /// under the same mounted tree and the window stops being about it.
    func test_control_theSweepStillClearsASubjectThatReallyWentAway() async throws {
        let store = try await collection(pieces: ["One"], notes: ["Ships"])
        let note = try XCTUnwrap(research(named: "Ships", in: store))
        let probe = BinderSubjectProbe(.research(note.id))
        _ = try await mountCollection(store: store, probe: probe)

        try await store.deleteResearchItem(id: note.id)
        _ = await pumpUntil(deadline: 5) { probe.subject != .research(note.id) }

        XCTAssertNotEqual(probe.subject, .research(note.id),
                          "control: the sweep is live under this mount, so the "
                          + "survival above is about the rescope and not about "
                          + "a sweep that never ran")
    }

    // MARK: - Fixtures

    /// The verbs as a row holds them, over ONE state object per test — so a
    /// store refusal (`pendingError`) is visible to `settle` instead of being
    /// a mystery about why nothing happened.
    private func verbs(_ store: ProjectStore) -> BinderTreeVerbs {
        BinderTreeVerbs(store: store, state: state(for: store),
                        selectedSubject: .constant(nil))
    }

    private func state(for store: ProjectStore) -> BinderTreeSectionsState {
        if let existing = states[ObjectIdentifier(store)] { return existing }
        let fresh = BinderTreeSectionsState()
        states[ObjectIdentifier(store)] = fresh
        return fresh
    }

    /// The drop verbs hand their work to a detached `Task`, exactly as every
    /// other verb in the tree does. Waits for what the caller is about to
    /// assert, then fails loudly if the store refused — the alert the writer
    /// would have seen is the same channel.
    private func settle(_ store: ProjectStore,
                        until condition: @escaping () -> Bool = { true }) async {
        _ = await pumpUntil(deadline: 5) {
            self.states[ObjectIdentifier(store)]?.pendingError != nil || condition()
        }
        pump(0.1)
        XCTAssertNil(states[ObjectIdentifier(store)]?.pendingError,
                     "the store refused the drop the tree accepted")
    }

    private func novel(notes: [String]) async throws -> ProjectStore {
        let url = try await ProjectFactory.createNovelProject(
            named: "Novel-\(UUID().uuidString.prefix(6))", in: temp.url)
        return try await furnish(try await ProjectStore.load(from: url), notes: notes)
    }

    private func collection(pieces: [String], notes: [String]) async throws -> ProjectStore {
        let url = try await ProjectFactory.createCollectionProject(
            named: "Collection-\(UUID().uuidString.prefix(6))", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let furnished = try await furnish(store, notes: notes)
        for title in pieces { _ = try await furnished.addLoosePiece(title: title, mode: .prose) }
        return furnished
    }

    private func screenplay(notes: [String]) async throws -> ProjectStore {
        let url = try await ProjectFactory.createScreenplayProject(
            named: "Screenplay-\(UUID().uuidString.prefix(6))", in: temp.url)
        return try await furnish(try await ProjectStore.load(from: url), notes: notes)
    }

    private func furnish(_ store: ProjectStore, notes: [String]) async throws -> ProjectStore {
        let ds = try await DocumentStore.open(url: store.url)
        store.documentStore = ds
        documentStores.append(ds)
        for title in notes {
            _ = try await store.addResearchTextNote(parentId: nil, title: title)
        }
        await store.wordCountPopulationTask?.value
        return store
    }

    /// A referenced piece: a second project on disk, linked into the
    /// Collection. Its research lives in that project, which is why the tree
    /// refuses to move anything into it.
    private func linkedReferencePiece(in store: ProjectStore) async throws -> StructureItem {
        let other = try await ProjectFactory.createShortStoryProject(
            named: "Elsewhere-\(UUID().uuidString.prefix(6))", in: temp.url)
        return try await store.addProjectReference(targetURL: other)
    }

    /// A real file on disk for an external drop to carry. Written under the
    /// test's own temp directory, so nothing here touches the writer's Finder.
    private func makeFile(named name: String, contents: String) throws -> URL {
        let dir = temp.url.appendingPathComponent("dropped-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A Finder drag's payload. `NSURL` registers `public.file-url`, which is
    /// the identifier `DropClassification` classifies on — so these tests go
    /// through the real classification rather than around it. (A browser drag
    /// carries a rendered bitmap instead and falls to the same classifier's
    /// `.image` arm; the file arm is the one the tree's routing turns on.)
    private func provider(for url: URL) -> NSItemProvider {
        NSItemProvider(object: url as NSURL)
    }

    private func research(named title: String, in store: ProjectStore) -> ResearchItem? {
        TreeWalk.first(in: store.manifest.research, where: { $0.title == title })
    }

    private func mountCollection(
        store: ProjectStore, probe: BinderSubjectProbe
    ) async throws -> NSWindow {
        let frame = CGRect(x: 0, y: 0, width: 320, height: 800)
        let hosting = NSHostingView(rootView: AnyView(
            DropRoutingProbeView(store: store, probe: probe)))
        hosting.frame = frame
        let window = SilentTestWindow(contentRect: frame, styleMask: [.titled],
                                      backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        windows.append(window)
        pump(0.3)
        return window
    }
}

/// The Collection tree with its subject bound to a probe, and the window's own
/// subject sweep attached — the sweep is what a rescope has to survive.
@MainActor
private struct DropRoutingProbeView: View {
    let store: ProjectStore
    let probe: BinderSubjectProbe
    @State private var renaming: String?
    let treeState = BinderTreeSectionsState()

    var body: some View {
        CollectionPiecesPane(
            store: store,
            selectedSubject: Binding(get: { probe.subject },
                                     set: { probe.subject = $0 }),
            renamingItemId: $renaming,
            treeState: treeState)
            .modifier(SubjectValidationModifier(
                store: store,
                selectedSubject: Binding(get: { probe.subject },
                                         set: { probe.subject = $0 })))
    }
}
