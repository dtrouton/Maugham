import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **The centre and the right column follow a research subject** (shell-finish
/// stage-2a Task 5, spec §4; shell p1 Task 2 asks it of the window's subject).
///
/// Two rules, and they differ by the subject's place:
///
/// - A research item **beside** (a click on its row) previews in the right
///   column and never moves the centre — the canvas stays exactly where it is
///   (an arm apiece was measured, 2026-08-02, and costs the writer's camera,
///   layouts and thumbnails on every selection), and the editor its document.
/// - A research item **opened** (the explicit gesture) takes the centre — the
///   note, the card or the preview — and the right column inspects it.
///
/// **The mounted half drives the REAL tree**, one per host: a row is selected
/// through `List(selection:)` and the assertion is about the surface that
/// actually reached the window. The route functions alone would pass over a
/// window that mounts nothing (the mode-UX lesson: 22 green undo tests on a ⌘Z
/// that could not reach the stack).
@MainActor
final class ResearchSubjectRoutingTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        // This suite mounts EditorSurface and the palette editor, both of which
        // style text through production typography.
        FontWarmup.ensure()
    }

    private var temp: TempDirectory!
    private var windows: [NSWindow] = []
    private var documentStores: [DocumentStore] = []
    private var defaultsSuites: [String] = []

    override func setUp() async throws {
        temp = TempDirectory()
    }

    override func tearDown() async throws {
        for window in windows { window.contentView = NSView(frame: .zero) }
        pump(0.05)
        windows.removeAll()
        for ds in documentStores { await ds.close() }
        documentStores.removeAll()
        for suite in defaultsSuites {
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        defaultsSuites.removeAll()
        temp.cleanup()
        temp = nil
    }

    // MARK: - Where the research subject lands

    /// **A research item in `open` takes the centre, whatever the faces are
    /// on** — a double-click or the explicit control put it there.
    func test_aResearchItemInOpenTakesTheCentre() {
        for faces in SubjectSamples.everyOpen {
            let subject = WindowSubject(open: .research("r1"), faces: faces)
            XCTAssertEqual(ProjectWindow.researchSubjectPlacement(subject: subject),
                           .takesTheCentre("r1"), "faces on \(faces)")
            XCTAssertEqual(ProjectWindow.centreRoute(
                subject: subject, bookView: .outline, projectType: .novel,
                structure: CentreRouteTests.structure, preview: .nothingCompiled),
                           .research(id: "r1"))
        }
    }

    /// **A beside item shows whatever the centre is** (shell p1 Task 4) — a
    /// research item open in the centre included, which used to win and leave
    /// the item the writer just clicked on no surface at all. The centre's own
    /// research item is carried, so the centre route does not lose it.
    func test_aBesideItemShowsWhateverTheCentreIs() {
        for open in SubjectSamples.everyOpen {
            let subject = WindowSubject(open: open, faces: open, beside: .research("r1"))
            let placement = ProjectWindow.researchSubjectPlacement(subject: subject)
            XCTAssertEqual(placement, .beside("r1", centre: open.researchID), "\(open) open")
            XCTAssertTrue(placement.previewsInTheRightColumn, "\(open): the item previews")
            XCTAssertEqual(placement.inspectedItemID, "r1", "\(open)")
            XCTAssertEqual(placement.centreItemID, open.researchID,
                           "\(open): the centre keeps what it shows")
        }
        // The same item in both places is the centre's: never mounted twice.
        let both = WindowSubject(open: .research("r1"), faces: .research("r1"),
                                 beside: .research("r1"))
        XCTAssertEqual(ProjectWindow.researchSubjectPlacement(subject: both),
                       .takesTheCentre("r1"))
    }

    /// **Open in Centre moves the beside item to the centre** — the click
    /// rule's `.openInCentre`, from every centre: it becomes `open` and the
    /// faces, and nothing is left beside. Close puts it away and moves
    /// nothing else. With nothing beside, both are no-ops.
    func test_openInCentreMovesTheBesideItemToTheCentre() {
        for open in SubjectSamples.everyOpen {
            let subject = WindowSubject(open: open, faces: .item(SubjectSamples.pieceID),
                                        beside: .research("r1"))
            let opened = ProjectWindow.openingBesideInCentre(
                subject, structure: SubjectSamples.structure, projectType: .novel)
            XCTAssertEqual(opened, WindowSubject(open: .research("r1"),
                                                 faces: .research("r1"), beside: nil),
                           "\(open) open")
            XCTAssertEqual(ProjectWindow.centreRoute(
                subject: opened, bookView: .outline, projectType: .novel,
                structure: CentreRouteTests.structure, preview: .nothingCompiled),
                           .research(id: "r1"), "\(open): the centre shows it")
            XCTAssertEqual(ProjectWindow.closingBeside(subject),
                           WindowSubject(open: open, faces: .item(SubjectSamples.pieceID),
                                         beside: nil), "\(open): close moves nothing else")
        }
        let nothing = SubjectSamples.opened(.canvas)
        XCTAssertEqual(ProjectWindow.openingBesideInCentre(
            nothing, structure: SubjectSamples.structure, projectType: .novel), nothing)
    }

    /// **The beside view's two controls are wired to those two functions and
    /// drawn as visible buttons** — read from the source, because pressing a
    /// mounted control and waiting is tripwire 33's shape.
    func test_theBesideViewCarriesOpenInCentreAndClose() throws {
        // The pulled-up view's header (shell p3 Task 7 moved it there).
        let source = try SourceTree.read("Maugham/Views/PulledUpView.swift")
        let code = SourceScan.codeLines(of: source).joined(separator: "\n")
        XCTAssertTrue(code.contains("ProjectWindow.openingBesideInCentre("),
                      "Open in Centre is the click rule's openInCentre")
        XCTAssertTrue(code.contains("ProjectWindow.closingBeside(subject)"))
        XCTAssertTrue(code.contains("Button(Self.openInCentreLabel, action: openInCentre)"),
                      "Open in Centre is a plain visible button")
        XCTAssertTrue(code.contains("Button(action: close)"))
        XCTAssertEqual(BesideHeader.openInCentreLabel, "Open in Centre")
    }

    /// **The right column's panes read the FACES, not what is open** — with the
    /// canvas, an edition or the Inbox in the centre and the faces on a piece,
    /// the panes are about that piece; with the faces on the Book, about no
    /// document.
    func test_theFacesReadTheFacesSubjectNotTheOpenOne() {
        let piece = SubjectSamples.pieceID
        for open in SubjectSamples.everyOpen {
            let subject = WindowSubject(open: open, faces: .item(piece))
            XCTAssertEqual(RightColumn.panesDocId(of: subject), piece, "\(open) open")
            XCTAssertEqual(RightColumn.panesItemID(of: subject), piece, "\(open) open")
        }
        let onTheBook = WindowSubject(open: .item(piece), faces: .project)
        XCTAssertEqual(RightColumn.panesDocId(of: onTheBook), BinderSubject.noDocumentSubject,
                       "an open piece with the faces on the Book is not the panes' document")
        XCTAssertNil(RightColumn.panesItemID(of: onTheBook))
    }

    /// **A research item beside previews in the right column and never takes
    /// the centre, whatever the centre is** — the canvas keeps its one mount
    /// (camera, layouts, thumbnails), the editor its document.
    func test_aResearchItemBesidePreviewsAndNeverTakesTheCentre() {
        for open in SubjectSamples.everyOpen where open.researchID == nil {
            let subject = WindowSubject(open: open, faces: open, beside: .research("r1"))
            XCTAssertEqual(ProjectWindow.researchSubjectPlacement(subject: subject),
                           .beside("r1"), "\(open) open")
            XCTAssertEqual(
                ProjectWindow.centreRoute(
                    subject: subject, bookView: .outline, projectType: .novel,
                    structure: CentreRouteTests.structure, preview: .nothingCompiled),
                ProjectWindow.centreRoute(
                    subject: SubjectSamples.opened(open), bookView: .outline,
                    projectType: .novel, structure: CentreRouteTests.structure,
                    preview: .nothingCompiled),
                "\(open): what is beside moves nothing in the centre")
        }
    }

    /// **A click on a research row puts it beside**, from every centre — the
    /// click rule's clause 2, asked rather than restated.
    func test_aClickedResearchRowGoesBesideFromEveryCentre() {
        for open in SubjectSamples.everyOpen where open.researchID == nil {
            let clicked = ClickRule.resolve(.research("r1"), gesture: .click,
                                            current: SubjectSamples.opened(open),
                                            structure: CentreRouteTests.structure,
                                            projectType: .novel)
            XCTAssertEqual(ProjectWindow.researchSubjectPlacement(subject: clicked).centreItemID,
                           nil, "\(open): the centre is never handed over by a click")
            XCTAssertEqual(ProjectWindow.researchSubjectPlacement(subject: clicked)
                .inspectedItemID, "r1")
        }
    }

    /// A subject naming no research item in either place leaves the columns
    /// alone.
    func test_aSubjectWithNoResearchLeavesBothColumnsAlone() {
        for subject in SubjectSamples.everySubject where subject.open.researchID == nil {
            XCTAssertEqual(ProjectWindow.researchSubjectPlacement(subject: subject),
                           .nothingMoves, "\(subject.open)")
        }
    }

    /// **The right column previews exactly when the centre is not showing the
    /// item** — the one sentence both columns are derived from, asserted over
    /// every case rather than trusted at each call site.
    func test_thePreviewIsShownExactlyWhereTheCentreIsNotShowingTheItem() {
        let placements: [ProjectWindow.ResearchSubjectPlacement] =
            [.takesTheCentre("r1"), .beside("r1"), .beside("r1", centre: "r2"), .nothingMoves]
        for placement in placements {
            XCTAssertEqual(
                placement.previewsInTheRightColumn,
                placement.inspectedItemID != nil
                    && placement.centreItemID != placement.inspectedItemID,
                "\(placement)")
        }
    }

    // MARK: - Which surface the centre shows

    /// **A palette card selected in the research tree edits through the visual
    /// editor.** `ResearchNoteEditor`'s stale open text clobbers the card model
    /// on the next re-render (a lost update), which is why the rule exists at
    /// all — and why it now lives in one function both arms call.
    func test_aPaletteCardRoutesToTheCardEditorAndNeverToTheNoteEditor() async throws {
        let store = try await novel(notes: [], cards: ["Harbour"])
        let card = try XCTUnwrap(store.paletteCardItems().first)

        let route = ProjectWindow.researchCentreRoute(
            id: card.id, in: store.manifest)

        XCTAssertEqual(route, .paletteCard(card.id))
    }

    func test_aTextNoteRoutesToTheNoteEditorWithItsPath() async throws {
        let store = try await novel(notes: ["Ships"], cards: [])
        let note = try XCTUnwrap(researchItem(named: "Ships", in: store))
        let path = try XCTUnwrap(note.path)

        XCTAssertEqual(
            ProjectWindow.researchCentreRoute(id: note.id, in: store.manifest),
            .note(item: note, path: path))
    }

    /// A kind the writer cannot edit here — a PDF, an image, a link, a group —
    /// is previewed. `ResearchPreview` is the same view the `.research` segment
    /// has always shown for these.
    func test_anUneditableKindRoutesToThePreview() async throws {
        let store = try await novel(notes: [], cards: [])
        let pdf = try await importPDF(named: "Tide tables", into: store)

        XCTAssertEqual(
            ProjectWindow.researchCentreRoute(id: pdf.id, in: store.manifest),
            .preview(pdf))
    }

    /// **A Research table opens in the grid** (report plan 8b Task 7): a CSV
    /// is no longer previewed as text, and both columns reach the grid
    /// through this one case.
    func test_aResearchTableRoutesToTheGridWithItsPath() async throws {
        let store = try await novel(notes: [], cards: [])
        let source = temp.url.appendingPathComponent("Tide heights.csv")
        try Data("Port,Metres\nDover,6.7\n".utf8).write(to: source)
        let imported = try await store.importResearchFiles([source], toParentId: nil)
        let table = try XCTUnwrap(imported.first)
        XCTAssertEqual(table.kind, .table, "fixture precondition")

        XCTAssertEqual(
            ProjectWindow.researchCentreRoute(id: table.id, in: store.manifest),
            .table(item: table, path: try XCTUnwrap(table.path)))
    }

    /// The render-race arm. The sweep lands a dangling id on `.project` before
    /// the routing sees it (Task 2), but a subject and a manifest arriving in
    /// different passes leave a window in which the id names nothing.
    func test_anIdThatNamesNothingRoutesToTheEmptyState() async throws {
        let store = try await novel(notes: ["Ships"], cards: [])

        XCTAssertEqual(
            ProjectWindow.researchCentreRoute(id: "no-such-item",
                                              in: store.manifest),
            .missing)
        XCTAssertEqual(
            ProjectWindow.researchCentreRoute(id: nil, in: store.manifest),
            .missing,
            "and the `.research` segment's own arm passes nil when nothing is "
            + "selected in the old pane")
    }

    /// **The palette rule is a path prefix ending in a SEPARATOR.** A group
    /// called "Palette research" gives its notes paths that begin with the
    /// palette folder's characters and are in no way inside it — and routing one
    /// of those to the card editor shows "Card unavailable" over a note the
    /// writer can see in their tree. Drop the `+ "/"` from the rule and this is
    /// the test that goes red.
    func test_aNoteBesideThePaletteFolderIsStillANote() async throws {
        let store = try await novel(notes: [], cards: [])
        let group = try await store.addResearchItem(
            parentId: nil, title: "Palette research", kind: nil)
        let note = try await store.addResearchTextNote(
            parentId: group.id, title: "Ships")
        let path = try XCTUnwrap(note.path)
        XCTAssertTrue(path.hasPrefix(ProjectStore.paletteFolderPath),
                      "fixture precondition: the path begins with the palette "
                      + "folder's characters — got \(path)")
        XCTAssertFalse(path.hasPrefix(ProjectStore.paletteFolderPath + "/"),
                       "…and is not inside it")

        XCTAssertEqual(
            ProjectWindow.researchCentreRoute(id: note.id, in: store.manifest),
            .note(item: note, path: path))
    }

    /// #141 N1 (RULING-61): a card is a card by its group's role. Renaming
    /// the Palette group moves its folder off `research/palette/`, and the
    /// card under it still opens in the card editor, never the note editor.
    func test_aCardUnderARenamedPaletteGroupRoutesToTheCardEditor() async throws {
        let store = try await novel(notes: [], cards: ["Harbour"])
        let group = try XCTUnwrap(store.paletteGroup())
        let added = try XCTUnwrap(store.paletteCardItems().first)
        try await store.updateResearchItem(id: group.id, title: "Moods")
        let card = try XCTUnwrap(TreeWalk.find(id: added.id, in: store.manifest.research))
        let path = try XCTUnwrap(card.path)
        XCTAssertFalse(path.hasPrefix(ProjectStore.paletteFolderPath + "/"),
                       "premise: the rename moved the card out of the palette folder — \(path)")

        XCTAssertEqual(ProjectWindow.researchCentreRoute(id: card.id, in: store.manifest),
                       .paletteCard(card.id))
    }

    /// The role decides both ways: a note moved in as a direct child of the
    /// Palette group is a card (what the wall shows), and a document in a
    /// subgroup beneath it is a note even though its path is inside the
    /// palette folder (the wall does not show it).
    func test_aNoteMovedIntoThePaletteGroupIsACard_andADocumentInASubgroupBeneathItIsANote() async throws {
        let store = try await novel(notes: ["Ships", "Loose"], cards: ["Harbour"])
        let group = try XCTUnwrap(store.paletteGroup())
        let ships = try XCTUnwrap(researchItem(named: "Ships", in: store))
        try await store.moveResearchItem(id: ships.id, toParentId: group.id, atIndex: 0)
        XCTAssertEqual(ProjectWindow.researchCentreRoute(id: ships.id, in: store.manifest),
                       .paletteCard(ships.id))

        let sub = try await store.addResearchItem(parentId: group.id, title: "Drafts", kind: nil)
        let loose = try XCTUnwrap(researchItem(named: "Loose", in: store))
        try await store.moveResearchItem(id: loose.id, toParentId: sub.id, atIndex: 0)
        let moved = try XCTUnwrap(TreeWalk.find(id: loose.id, in: store.manifest.research))
        let path = try XCTUnwrap(moved.path)
        XCTAssertTrue(path.hasPrefix(ProjectStore.paletteFolderPath + "/"),
                      "premise: the subgroup's document sits inside the palette folder — \(path)")
        XCTAssertEqual(ProjectWindow.researchCentreRoute(id: moved.id, in: store.manifest),
                       .note(item: moved, path: path))
    }

    /// The legacy fallback: with no palette group in the manifest (neither a
    /// role-stamped group nor one at `research/palette`), the folder prefix
    /// still decides, separator and all.
    func test_withNoPaletteGroupThePathPrefixStillDecides() async throws {
        let store = try await novel(notes: [], cards: [])
        XCTAssertNil(PaletteLookup.paletteGroup(in: store.manifest.research), "premise: no palette group")
        let inside = ResearchItem(id: "res-fallb001", title: "Inside", type: .asset,
                                  kind: .document, path: ProjectStore.paletteFolderPath + "/x.md")
        let beside = ResearchItem(id: "res-fallb002", title: "Beside", type: .asset,
                                  kind: .document, path: "research/palettes/x.md")
        store.manifest.research.append(contentsOf: [inside, beside])
        let structure = store.manifest.structure, research = store.manifest.research

        XCTAssertEqual(ResearchTextRole.of(inside, structure: structure, research: research), .paletteCard)
        XCTAssertEqual(ResearchTextRole.of(beside, structure: structure, research: research),
                       .note(path: "research/palettes/x.md"))
    }

    /// A legacy palette group — at `research/palette`, never role-stamped —
    /// still holds its cards: a direct document child is a card, and a
    /// document in a subgroup beneath it is a note.
    func test_aLegacyUnstampedPaletteGroupStillHoldsCards() async throws {
        let store = try await novel(notes: [], cards: [])
        let card = ResearchItem(id: "res-legcy001", title: "Harbour", type: .asset,
                                kind: .document, path: ProjectStore.paletteFolderPath + "/harbour.md")
        let nested = ResearchItem(id: "res-legcy002", title: "Draft", type: .asset,
                                  kind: .document, path: ProjectStore.paletteFolderPath + "/drafts/draft.md")
        let sub = ResearchItem(id: "res-legcy003", title: "Drafts", type: .group,
                               path: ProjectStore.paletteFolderPath + "/drafts", children: [nested])
        let group = ResearchItem(id: "res-legcy004", title: "Palette", type: .group,
                                 path: ProjectStore.paletteFolderPath, children: [card, sub])
        store.manifest.research = [group]
        XCTAssertNil(group.role, "premise: the group carries no role stamp")
        XCTAssertEqual(PaletteLookup.paletteGroup(in: store.manifest.research)?.id, group.id,
                       "premise: found by its legacy path")
        let structure = store.manifest.structure, research = store.manifest.research

        XCTAssertEqual(ResearchTextRole.of(card, structure: structure, research: research), .paletteCard)
        XCTAssertEqual(ResearchTextRole.of(nested, structure: structure, research: research),
                       .note(path: ProjectStore.paletteFolderPath + "/drafts/draft.md"))
    }

    /// **A text item outside a research root is not an editable note**
    /// (note versions plan 2, whole-branch C2): a synced manifest listing the
    /// manuscript or a `.maugham/` file as a Research `.document` routes to
    /// the read-only preview, never to `ResearchNoteEditor` (whose saves go
    /// through a door that would refuse them).
    func test_aTextItemOutsideAResearchRootRoutesToThePreview() async throws {
        let store = try await novel(notes: [], cards: [])
        for (n, path) in ["manuscript/stray.md", ".maugham/ops/stray.jsonl", "research-old/x.md"].enumerated() {
            let stray = ResearchItem(id: "res-route00\(n)", title: "Stray", type: .asset,
                                     kind: .document, path: path)
            store.manifest.research.append(stray)
            XCTAssertEqual(ProjectWindow.researchCentreRoute(id: stray.id, in: store.manifest),
                           .preview(stray), path)
        }
    }

    /// **Both columns derive from the SAME route value** (final-review finding
    /// I3).
    ///
    /// `researchCentreRoute` exists so the centre column and the right column
    /// cannot answer differently about what a research item IS. The centre half
    /// called it; the right half did not, and mounted `ResearchPreview` for
    /// everything — so in Plan, where that column is the writer's only view of
    /// the item, a palette card previewed as the markdown of its source.
    ///
    /// A census rather than a behavioural test because the claim is about
    /// *where the decision is made*: a right column that happened to draw a card
    /// correctly by re-deriving the palette-path rule would pass every mounted
    /// assertion and be exactly the drift this function was extracted against.
    func test_bothColumnsAskTheSameRoutingFunction() throws {
        let source = try CanvasSourceCensus.source(
            at: "Maugham/Views/ResearchSubjectColumns.swift")
        for view in ["struct ResearchSubjectCentre: View {",
                     "struct ResearchSubjectInspector: View {"] {
            let body = try XCTUnwrap(declaration(startingAt: view, in: source),
                                     "\(view) is not in this file any more")
            XCTAssertTrue(
                body.contains("researchCentreRoute("),
                "\(view) must ASK the route rather than decide for itself — one "
                + "function is what keeps the two columns from disagreeing about "
                + "whether an item is a card, a note or a preview")
        }
        // The note-or-card rule moved to the store layer (note versions
        // plan 2, Task 2) so the note door asks the same predicate.
        XCTAssertEqual(
            occurrences(of: "ProjectStore.paletteFolderPath", in: source), 0,
            "the palette-path rule is not spelled in the view: "
            + "`researchCentreRoute` asks `ResearchTextRole.of`")
        XCTAssertEqual(occurrences(of: "ResearchTextRole.of(", in: source), 1)
        let predicate = try CanvasSourceCensus.source(at: "Maugham/Stores/ResearchNoteDoor.swift")
        XCTAssertEqual(
            occurrences(of: "ProjectStore.paletteFolderPath", in: predicate), 1,
            "and it is spelled exactly once, inside `ResearchTextRole.of` — a "
            + "second copy is the drift with extra steps")
    }

    // MARK: - The metrics zero themselves (contract 3)

    /// Asserted rather than re-implemented: the window already zeroes the
    /// inspector/footer metrics for any subject that is not a manuscript
    /// document, and a research subject has no `itemID` at all.
    func test_aResearchSubjectIsNotADocumentSoTheWindowsMetricsZero() async throws {
        let store = try await novel(notes: ["Ships"], cards: [])
        let note = try XCTUnwrap(researchItem(named: "Ships", in: store))
        let document = try XCTUnwrap(
            TreeWalk.first(in: store.manifest.structure, where: { $0.type == .document }))

        XCTAssertFalse(
            ProjectWindow.selectionIsDocument(.research(note.id),
                                              in: store.manifest.structure),
            "a research subject is not a document, so the metrics the "
            + "EditorCoordinator can no longer deliver are zeroed")
        XCTAssertTrue(
            ProjectWindow.selectionIsDocument(.item(document.id),
                                              in: store.manifest.structure),
            "control: a manuscript document still is one")
    }

    /// **And the manuscript status footer goes with them.** The footer's four
    /// readings are all about a manuscript document; over a research note in
    /// the centre there is none. A note BESIDE leaves the document in the
    /// centre, and the footer with it.
    func test_theManuscriptStatusFooterIsSilentWhenAResearchItemTookTheCentre() {
        let piece = SubjectSamples.opened(.item("doc1"))
        XCTAssertTrue(ProjectWindow.showsStatusFooter(subject: piece, structure: Self.oneDocument),
                      "control: a manuscript document in the centre still reports")
        XCTAssertFalse(ProjectWindow.showsStatusFooter(
            subject: SubjectSamples.opened(.research("r1")), structure: Self.oneDocument),
                       "a research item in the centre has no document for the footer")
        var beside = piece
        beside.beside = .research("r1")
        XCTAssertTrue(ProjectWindow.showsStatusFooter(subject: beside, structure: Self.oneDocument),
                      "a note beside leaves the document — and the footer — in the centre")
        // **The centre decides**: faces on a document cannot conjure a footer
        // over a centre that is not one.
        for open in SubjectSamples.everyOpen where open != .item(SubjectSamples.pieceID) {
            XCTAssertFalse(ProjectWindow.showsStatusFooter(
                subject: WindowSubject(open: open, faces: .item("doc1")),
                structure: Self.oneDocument), "\(open) open")
        }
    }

    /// **The wall term.** The palette wall is the centre while it is open, so
    /// the goal capsule and the `¶id`/element readouts have nothing under them.
    func test_theManuscriptStatusFooterIsSilentUnderThePaletteWall() {
        var subject = SubjectSamples.opened(.item("doc1"))
        XCTAssertTrue(ProjectWindow.showsStatusFooter(subject: subject, structure: Self.oneDocument),
                      "control: the wall closed, the document reports")
        subject = ClickRule.resolve(.palette, gesture: .click, current: subject, structure: SubjectSamples.structure, projectType: .novel)
        XCTAssertFalse(ProjectWindow.showsStatusFooter(subject: subject, structure: Self.oneDocument),
                       "the wall is the centre — the footer's readings have nothing to report on")
    }

    /// The structure the footer's `doc1` subject is looked up in: a bare id
    /// with no structure behind it would read as dangling, and every "control:
    /// still reports" assertion above would be inverted.
    static let oneDocument: [StructureItem] = [
        StructureItem(id: "doc1", title: "Chapter One", type: .document,
                      path: "manuscript/chapter-1.md")
    ]

    // MARK: - Mounted: the note goes beside, through each tree

    func test_aNoteClickedInTheNovelTreeGoesBesideAndOpenedTakesTheCentre() async throws {
        let store = try await novel(notes: ["Ships"], cards: [])
        let note = try XCTUnwrap(researchItem(named: "Ships", in: store))
        try seedNoteText(Self.noteText, at: note, in: store)

        let mount = try await host(store: store, tree: .binder, isLocked: false)
        let table = try XCTUnwrap(firstTableView(in: mount.window))
        await select(row: 1 + TreeFurniture.topRows + store.manifest.structure.count + 1, in: table,
                     until: { mount.probe.subject.beside == .research(note.id) })

        try await assertTheNoteIsBesideThenInTheCentre(of: mount, note: note)
    }

    func test_aNoteClickedInTheCollectionTreeGoesBesideAndOpenedTakesTheCentre() async throws {
        let store = try await collection(pieces: ["One"], notes: ["Ships"], cards: [])
        let note = try XCTUnwrap(researchItem(named: "Ships", in: store))
        try seedNoteText(Self.noteText, at: note, in: store)

        let mount = try await host(store: store, tree: .collection, isLocked: false)
        let table = try XCTUnwrap(firstTableView(in: mount.window))
        await select(row: 1 + TreeFurniture.topRows + store.manifest.structure.count + 1, in: table,
                     until: { mount.probe.subject.beside == .research(note.id) })

        try await assertTheNoteIsBesideThenInTheCentre(of: mount, note: note)
    }

    func test_aNoteClickedInTheScreenplayTreeGoesBesideAndOpenedTakesTheCentre() async throws {
        let store = try await screenplay(notes: ["Ships"], cards: [])
        let note = try XCTUnwrap(researchItem(named: "Ships", in: store))
        try seedNoteText(Self.noteText, at: note, in: store)

        let mount = try await host(store: store, tree: .navigator, isLocked: false)
        let table = try XCTUnwrap(firstTableView(in: mount.window))
        // project, script, two sluglines, the Research header, then the note.
        await select(row: 5 + TreeFurniture.topRows, in: table,
                     until: { mount.probe.subject.beside == .research(note.id) })

        try await assertTheNoteIsBesideThenInTheCentre(of: mount, note: note)
    }

    /// **A locked window's centre locks a note opened there** (shell p1 Task
    /// 5; Review's read-only centre before it, shell-finish stage 3b Task 6)
    /// — `WindowLock.refusesEdits` is the question.
    func test_aNoteOpenedInALockedWindowReachesTheCentreLocked() async throws {
        let store = try await novel(notes: ["Ships"], cards: [])
        let note = try XCTUnwrap(researchItem(named: "Ships", in: store))
        try seedNoteText(Self.noteText, at: note, in: store)

        let mount = try await host(store: store, tree: .binder, isLocked: true,
                                   subject: SubjectSamples.opened(.research(note.id)))

        await pumpUntil(deadline: 5) {
            self.textViews(in: mount.window).contains { $0.string.contains(Self.noteText) }
        }
        let editor = try XCTUnwrap(
            textViews(in: mount.window).first { $0.string.contains(Self.noteText) },
            "a locked window must still show the note's own text — locked, not hidden")
        XCTAssertEqual(editor.coordinator?.lockEditing, true)
    }

    // MARK: - Mounted: the palette card takes the card editor

    /// The lost-update precedent, on the delivery path: a card row in the tree
    /// is research like any other, and wherever it is drawn it must be the
    /// visual editor rather than a text editor holding the card's source.
    func test_aPaletteCardClickedInTheTreeMountsTheCardEditorNotTheNoteEditor() async throws {
        let store = try await novel(notes: ["Ships"], cards: ["Harbour"])
        let card = try XCTUnwrap(store.paletteCardItems().first)

        let mount = try await host(store: store, tree: .binder, isLocked: false)
        let table = try XCTUnwrap(firstTableView(in: mount.window))
        // the project row, the chapters, Research (header + note), then the
        // Palette header and the card.
        await select(row: 1 + TreeFurniture.topRows + store.manifest.structure.count + 2
                            + TreeFurniture.paletteHead, in: table,
                     until: { mount.probe.subject.beside == .research(card.id) })

        XCTAssertEqual(mount.probe.subject.beside, .research(card.id), "precondition")
        await pumpUntil(deadline: 5) { !self.segmentedControls(in: mount.window).isEmpty }
        XCTAssertFalse(
            segmentedControls(in: mount.window).isEmpty,
            "PaletteCardEditor's Kind picker is a segmented control and nothing "
            + "else in this window mounts one — the card must reach the visual "
            + "editor")
        XCTAssertTrue(
            textViews(in: mount.window).isEmpty,
            "…and never ResearchNoteEditor, whose stale open text clobbers the "
            + "card model on the next re-render (the lost update the rule exists "
            + "for)")
    }

    // MARK: - Mounted: the canvas keeps the centre

    /// **A research click with the canvas open previews the item and leaves the
    /// board alone.** Both halves are the assertion: the canvas is not rebuilt (its
    /// `load()` count does not move), and the right column shows the item.
    func test_aResearchClickWithTheCanvasOpenPreviewsBesideACanvasThatIsNeverRebuilt() async throws {
        let store = try await novel(notes: [], cards: [])
        let pdf = try await importPDF(named: "Tide tables", into: store)

        let mount = try await host(store: store, tree: .binder, isLocked: false,
                                   subject: SubjectSamples.opened(.canvas))
        await pumpUntil(deadline: 5) { mount.canvasLoads.count >= 1 }
        let loadsBefore = mount.canvasLoads.count
        XCTAssertGreaterThan(loadsBefore, 0,
                             "precondition: the canvas is the centre column")
        let boardBefore = try XCTUnwrap(canvasViews(in: mount.window).first,
                                        "precondition: the board is mounted")

        let table = try XCTUnwrap(firstTableView(in: mount.window))
        await select(row: 1 + TreeFurniture.topRows + store.manifest.structure.count + 1, in: table,
                     until: { mount.probe.subject.beside == .research(pdf.id) })
        XCTAssertEqual(mount.probe.subject.beside, .research(pdf.id), "precondition")
        XCTAssertEqual(mount.probe.subject.open, .canvas, "precondition: the click moved no centre")

        await pumpUntil(deadline: 5) { !self.pdfViews(in: mount.window).isEmpty }
        XCTAssertFalse(
            pdfViews(in: mount.window).isEmpty,
            "the right column previews the item — otherwise a research click "
            + "over the canvas changes nothing anywhere")
        XCTAssertEqual(
            mount.canvasLoads.count, loadsBefore,
            "…and the canvas was not rebuilt. A second centre-column branch "
            + "costs the camera, the layouts and the thumbnail cache on every "
            + "research click (CanvasTreeSegmentMountTests measured it)")
        XCTAssertTrue(
            canvasViews(in: mount.window).contains { $0 === boardBefore },
            "…and it is the SAME board, still in the centre. The load count "
            + "alone cannot see the other half of the failure: a placement that "
            + "gave the centre away would UNMOUNT the canvas, which runs no "
            + "load at all")
    }

    /// **The canvas inspector is reachable with the canvas open, and research
    /// beside is what deliberately replaces it.**
    ///
    /// This was the 2a Critical's mounted half, and its premise was the state
    /// stage 2b Task 7 removed. Plan's Canvas tab mounted the old research pane,
    /// which wrote its own private selection and never the window's subject —
    /// so a research subject arriving with the writer (from Plan's Structure
    /// tab, or restored from `UIState` into the tab Plan landed on) replaced the
    /// region, scrap, line and item inspectors and every Promote button with
    /// them, for the session and again after a relaunch. The refusal that fixed
    /// it was `.segmentStands` for that one tab.
    ///
    /// Plan has one left column now and it is the tree, so the subject can
    /// always be cleared and the refusal has nothing left to protect. What is
    /// asserted instead is the pair that matters: **the region inspector is
    /// there with no research subject in force, and the preview is what takes
    /// the column when one arrives** — which is `besideTheCanvas`'s whole
    /// contract, and the reason it is not a regression is
    /// `ProjectSubjectReachabilityTests`, which drives the tree row that gives
    /// the column back.
    ///
    /// Mounted rather than reasoned about, because the claim is about a column
    /// that mounts — a replaced arm and an unrequested one are the same value.
    func test_theCanvasInspectorIsReachableWithTheCanvasOpenAndResearchBesideReplacesIt() async throws {
        let store = try await novel(notes: ["Ships"], cards: [])
        let note = try XCTUnwrap(researchItem(named: "Ships", in: store))

        let model = CanvasModel()
        let mount = try await host(store: store, tree: .binder, isLocked: false,
                                   subject: SubjectSamples.opened(.canvas), canvasModel: model)

        // Seeded AFTER the mount: `CanvasView`'s `.onAppear` load replaces the
        // scene, so a region put in before it would be gone by the time the
        // right column drew anything.
        let regionID = CanvasRegionID("r1")
        model.withScene {
            $0.insertRegion(CanvasRegion(
                id: regionID, label: Self.regionLabel,
                frame: CGRect(x: 0, y: 0, width: 600, height: 400)))
        }
        model.selection = .region(regionID)
        pump(0.2)

        await pumpUntil(deadline: 5) {
            self.textFields(in: mount.window).contains {
                $0.stringValue == Self.regionLabel
            }
        }
        XCTAssertTrue(
            textFields(in: mount.window).contains { $0.stringValue == Self.regionLabel },
            "the selected region's own name field must be in the right column "
            + "while the canvas is open — without it the region, scrap, line and "
            + "item inspectors are unreachable")

        mount.probe.subject.beside = .research(note.id)
        await pumpUntil(deadline: 5) {
            !self.textFields(in: mount.window).contains {
                $0.stringValue == Self.regionLabel
            }
        }
        XCTAssertFalse(
            textFields(in: mount.window).contains { $0.stringValue == Self.regionLabel },
            "and a research subject takes the right column — that is what "
            + "`besideTheCanvas` means, and a tree row is what gives it back")
    }

    /// **A palette card previewed beside the canvas is a CARD** (finding I3).
    ///
    /// The right column is the writer's only view of an item beside, and it
    /// mounted `ResearchPreview` for everything — so a card previewed as the raw
    /// markdown of its source file, which is the exact rendering
    /// `researchCentreRoute` was extracted to stop the window showing. The
    /// function existed and this column did not call it.
    func test_aPaletteCardPreviewedBesideTheCanvasIsDrawnAsACard() async throws {
        let store = try await novel(notes: [], cards: ["Harbour"])
        let card = try XCTUnwrap(store.paletteCardItems().first)

        let mount = try await host(store: store, tree: .binder, isLocked: false,
                                   subject: WindowSubject(open: .canvas, faces: .canvas,
                                                          beside: .research(card.id)))
        XCTAssertEqual(mount.probe.subject.beside, .research(card.id), "precondition")

        await pumpUntil(deadline: 5) { !self.segmentedControls(in: mount.window).isEmpty }
        XCTAssertFalse(
            segmentedControls(in: mount.window).isEmpty,
            "PaletteCardEditor's Kind picker is a segmented control and nothing "
            + "else in this window mounts one — the card must be drawn as a card "
            + "in the preview half, not as the markdown of its source")
    }

    // MARK: - Shared mounted assertions

    /// The click put the note beside: the right column inspects it (its Title
    /// field) and the centre holds no note editor. Then the explicit gesture
    /// (`ClickRule`'s `.openInCentre`) opens it in the centre.
    private func assertTheNoteIsBesideThenInTheCentre(
        of mount: Mount, note: ResearchItem,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        XCTAssertEqual(mount.probe.subject.beside, .research(note.id),
                       "precondition: the tree wrote the note beside", file: file, line: line)
        XCTAssertNil(mount.probe.subject.open.researchID,
                     "a click never hands the centre to research", file: file, line: line)

        await pumpUntil(deadline: 5) {
            self.textFields(in: mount.window).contains { $0.stringValue == note.title }
        }
        XCTAssertTrue(
            textFields(in: mount.window).contains { $0.stringValue == note.title },
            "the right column inspects it — InspectorResearchPanel's Title field "
            + "carries the item's own title", file: file, line: line)

        mount.probe.subject = ClickRule.resolve(
            .research(note.id), gesture: .openInCentre, current: mount.probe.subject,
            structure: [], projectType: .novel)
        await pumpUntil(deadline: 5) {
            self.textViews(in: mount.window).contains { $0.string.contains(Self.noteText) }
        }
        let editors = textViews(in: mount.window)
        XCTAssertTrue(
            editors.contains { $0.string.contains(Self.noteText) },
            "opened, the note is the note in the centre column — found "
            + "\(editors.count) editor(s) holding "
            + "\(editors.map { String($0.string.prefix(40)) })",
            file: file, line: line)
    }

    // MARK: - Fixtures

    private static let noteText = "Ships at anchor, unhurried."

    /// A region name no other surface in the mounted window can be showing, so
    /// finding it in a text field is finding the region inspector.
    private static let regionLabel = "Act II fog"

    private static let twoScenes = FountainTokenizer().parse(
        "INT. KITCHEN - DAY\n\nLarry sits.\n\nEXT. ROOF - NIGHT\n\nHe climbs.\n")

    private func novel(notes: [String], cards: [String]) async throws -> ProjectStore {
        let url = try await ProjectFactory.createNovelProject(
            named: "Novel-\(UUID().uuidString.prefix(6))", in: temp.url)
        return try await furnish(try await ProjectStore.load(from: url),
                                 notes: notes, cards: cards)
    }

    private func collection(pieces: [String], notes: [String],
                            cards: [String]) async throws -> ProjectStore {
        let url = try await ProjectFactory.createCollectionProject(
            named: "Collection-\(UUID().uuidString.prefix(6))", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        for title in pieces { _ = try await store.addLoosePiece(title: title, format: .markdown) }
        return try await furnish(store, notes: notes, cards: cards)
    }

    private func screenplay(notes: [String], cards: [String]) async throws -> ProjectStore {
        let url = try await ProjectFactory.createScreenplayProject(
            named: "Screenplay-\(UUID().uuidString.prefix(6))", in: temp.url)
        return try await furnish(try await ProjectStore.load(from: url),
                                 notes: notes, cards: cards)
    }

    private func furnish(_ store: ProjectStore, notes: [String],
                         cards: [String]) async throws -> ProjectStore {
        let ds = try await DocumentStore.open(url: store.url)
        store.documentStore = ds
        documentStores.append(ds)
        for title in notes {
            _ = try await store.addResearchTextNote(parentId: nil, title: title)
        }
        for title in cards {
            _ = try await store.addPaletteCard(title: title, kind: .location)
        }
        await store.wordCountPopulationTask?.value
        return store
    }

    /// A research item the centre column can only PREVIEW. A PDF rather than a
    /// link: `LinkPreview` is a `WKWebView` and would reach the network.
    private func importPDF(named title: String,
                           into store: ProjectStore) async throws -> ResearchItem {
        let source = temp.url.appendingPathComponent("\(title).pdf")
        try Data("%PDF-1.4\n%%EOF\n".utf8).write(to: source)
        let imported = try await store.importResearchFiles([source], toParentId: nil)
        let item = try XCTUnwrap(imported.first)
        XCTAssertEqual(item.kind, .pdf, "fixture precondition")
        return item
    }

    private func researchItem(named title: String, in store: ProjectStore) -> ResearchItem? {
        TreeWalk.first(in: store.manifest.research, where: { $0.title == title })
    }

    /// `ResearchNoteEditor` loads the note's text off disk, so the words the
    /// centre column shows are the words in the file.
    private func seedNoteText(_ text: String, at item: ResearchItem,
                              in store: ProjectStore) throws {
        let path = try XCTUnwrap(item.path)
        try Data(text.utf8).write(to: store.url.appendingPathComponent(path))
    }

    // MARK: - Hosting

    private typealias Tree = ResearchSubjectRoutingProbeTree

    private struct Mount {
        let window: NSWindow
        let probe: WindowSubjectProbe
        let canvasLoads: CanvasLoadCounter
    }

    /// - Parameters:
    ///   - subject: the window's subject **before the first render** — `UIState`
    ///     restores one on launch. Seeded on the probe rather than clicked: the
    ///     tree has no canvas row until shell p1 Task 3.
    ///   - isLocked: the window's Lock, as production's `CentreColumn` asks it.
    ///   - canvasModel: the board the centre and the region inspector share.
    ///     Given by a caller that has selected something on it.
    private func host(store: ProjectStore, tree: Tree,
                      isLocked: Bool,
                      subject: WindowSubject = .book,
                      canvasModel: CanvasModel = CanvasModel()) async throws -> Mount {
        let probe = WindowSubjectProbe(subject)
        let counter = CanvasLoadCounter()
        let suite = "research-subject-routing-\(UUID().uuidString)"
        defaultsSuites.append(suite)
        let preferences = UserPreferences(defaults: UserDefaults(suiteName: suite)!)
        let documentStore = try XCTUnwrap(store.documentStore)

        let root = ResearchRoutingProbeView(
            store: store,
            documentStore: documentStore,
            tree: tree,
            isLocked: isLocked,
            script: tree == .navigator ? Self.twoScenes : nil,
            documentID: TreeWalk.first(in: store.manifest.structure,
                                       where: { $0.type == .document })?.id,
            probe: probe,
            canvasModel: canvasModel,
            canvasLoads: counter)
            .environment(preferences)

        let window = TestWindow.mount(AnyView(root),
                                      size: CGSize(width: 1200, height: 800),
                                      as: SilentTestWindow.self)
        windows.append(window)
        await pumpUntil(deadline: 5) { self.firstTableView(in: window) != nil }
        // The palette section loads its cards from disk once per manifest
        // change, so its rows arrive a turn after the table does.
        pump(0.2)
        return Mount(window: window, probe: probe, canvasLoads: counter)
    }

    private func select(row: Int, in table: NSTableView,
                        until settled: (() -> Bool)? = nil) async {
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        if let settled {
            await pumpUntil(deadline: 5, settled)
        } else {
            await waitOut(0.4)
        }
    }

    // MARK: - Reading the mounted window

    private func firstTableView(in window: NSWindow) -> NSTableView? {
        collect(NSTableView.self, in: window).first
    }

    private func textViews(in window: NSWindow) -> [MaughamTextView] {
        collect(MaughamTextView.self, in: window)
    }

    private func textFields(in window: NSWindow) -> [NSTextField] {
        collect(NSTextField.self, in: window)
    }

    private func segmentedControls(in window: NSWindow) -> [NSSegmentedControl] {
        collect(NSSegmentedControl.self, in: window)
    }

    private func canvasViews(in window: NSWindow) -> [CanvasEventNSView] {
        collect(CanvasEventNSView.self, in: window)
    }

    private func pdfViews(in window: NSWindow) -> [NSView] {
        collect(NSView.self, in: window)
            .filter { String(describing: type(of: $0)).contains("PDFView") }
    }

    // MARK: - Reading the source

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    /// A top-level declaration, from its opening line to the closing brace at
    /// file indentation — bounded, or every "body" would be the rest of the file
    /// and the assertions over it could not fail.
    private func declaration(startingAt header: String, in source: String) -> String? {
        guard let start = source.range(of: header) else { return nil }
        let rest = source[start.lowerBound...]
        guard let end = rest.range(of: "\n}\n") else { return String(rest) }
        return String(rest[..<end.upperBound])
    }

    private func collect<T: NSView>(_ type: T.Type, in window: NSWindow) -> [T] {
        guard let root = window.contentView else { return [] }
        var found: [T] = []
        collect(type, in: root, into: &found)
        return found
    }

    private func collect<T: NSView>(_ type: T.Type, in view: NSView, into out: inout [T]) {
        if let hit = view as? T { out.append(hit) }
        for sub in view.subviews { collect(type, in: sub, into: &out) }
    }
}

// MARK: - Probes

/// How many times the mounted canvas has run its `.onAppear` load — the
/// production path `CanvasTreeSegmentMountTests` counts, so a rebuilt canvas is
/// visible as the number moving rather than through an instrument invented for
/// this test.
@MainActor
final class CanvasLoadCounter {
    private(set) var count = 0
    func record() { count += 1 }
}

/// **The three columns, wired the way `ProjectWindow` wires them.**
///
/// The tree is production's own (all three hosts), its binding is the window's
/// (`WindowSubjectProbe.treeBinding`: `beside ?? faces`, written through
/// `ClickRule`), and both other columns are chosen by the SAME
/// `ProjectWindow.centreRoute` and `researchSubjectPlacement` the window's
/// columns read. Nothing here re-spells the rule — a probe that decided for
/// itself which column gets the item would be testing the probe.
@MainActor
private struct ResearchRoutingProbeView: View {
    let store: ProjectStore
    let documentStore: DocumentStore
    let tree: ResearchSubjectRoutingProbeTree
    let isLocked: Bool
    let script: FountainScript?
    let documentID: String?
    let probe: WindowSubjectProbe
    let canvasModel: CanvasModel
    let canvasLoads: CanvasLoadCounter

    @State private var renaming: String?
    let treeState = BinderTreeSectionsState()

    private var placement: ProjectWindow.ResearchSubjectPlacement {
        ProjectWindow.researchSubjectPlacement(subject: probe.subject)
    }

    private var route: CentreRoute {
        ProjectWindow.centreRoute(subject: probe.subject, bookView: .outline,
                                  projectType: store.manifest.type,
                                  structure: store.manifest.structure,
                                  preview: .nothingCompiled)
    }

    var body: some View {
        HStack(spacing: 0) {
            treeColumn.frame(width: 300)
            centre.frame(maxWidth: .infinity, maxHeight: .infinity)
            right.frame(width: 320)
        }
    }

    @ViewBuilder
    private var treeColumn: some View {
        let subject = probe.binding
        switch tree {
        case .binder:
            BinderView(store: store, subject: subject,
                       treeState: treeState)
        case .collection:
            CollectionPiecesPane(store: store, subject: subject,
                                 renamingItemId: $renaming,
                                 treeState: treeState)
        case .navigator:
            SceneNavigatorPane(store: store, script: script,
                               projectTitle: store.manifest.title,
                               subject: subject,
                               documentID: documentID,
                               treeState: treeState,
                               onSelect: { _ in })
        }
    }

    @ViewBuilder
    private var centre: some View {
        switch route {
        case .research(let id):
            ResearchSubjectCentre(store: store, documentStore: documentStore,
                                  itemID: id, previewVisible: false,
                                  readOnly: WindowLock.refusesEdits(isLocked: isLocked))
        case .canvas:
            CanvasView(model: canvasModel, projectRoot: store.url,
                       paletteSwatchHexes: { canvasLoads.record(); return [] })
        default:
            Color.clear
        }
    }

    /// **The right column, with production's own fallback.**
    ///
    /// `researchOrSubject` asks the placement first and `inspectorRoute` second,
    /// so where the canvas is open the region inspector is what the column
    /// falls back to. Modelling only the research half made the probe unable to
    /// see the failure the final review found: an inspector arm that is
    /// REPLACED looks exactly like one that was never asked for.
    @ViewBuilder
    private var right: some View {
        if let id = placement.inspectedItemID {
            ResearchSubjectInspector(store: store, itemID: id,
                                     showsPreview: placement.previewsInTheRightColumn)
        } else if ProjectWindow.inspectorRoute(subject: probe.subject,
                                               projectType: store.manifest.type) == .canvas {
            RegionInspectorPane(model: canvasModel, pieces: [],
                                artifactTitle: { _ in nil }, pieceTitle: { _ in nil },
                                onOpenResearchItem: { _ in })
        } else {
            Color.clear
        }
    }
}

/// The probe's tree choice, at file scope because a nested type cannot be named
/// from the test's own `private enum Tree` across the file boundary.
enum ResearchSubjectRoutingProbeTree { case binder, collection, navigator }
