import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **The centre and the right column follow a research subject** (shell-finish
/// stage-2a Task 5, spec §4).
///
/// Task 4 gave every persona's tree a Research and a Palette section, so every
/// tree can now name a research item as the window's subject. This is the other
/// half: what the rest of the window does about it.
///
/// Two rules, and they differ by column:
///
/// - Where the centre is **not** the canvas, the research subject takes the
///   centre — the note, the card or the preview — and the right column inspects
///   it. That is spec §4's Author cell.
/// - Where the centre **is** the canvas (Plan), the canvas stays exactly where
///   it is and the right column previews the item instead. An arm apiece was
///   measured at the time (macOS 26.5, 2026-08-02) and costs the writer's
///   camera, layouts and thumbnails on every selection — so a research click in
///   Plan must not swap the centre.
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

    /// Every persona whose centre is a document — and whose centre is not the
    /// compiled book — hands it over.
    ///
    /// **It used to be asked of a (persona, segment) product**, and two of those
    /// segments were the stage-2a final review's Critical: `.find` and `.trash`
    /// both let a research item take the centre while their left panes wrote no
    /// subject at all, so the item could never be dismissed. Both are window
    /// state now rather than surfaces, and shell-finish stage 2b Task 7 took the
    /// enum with them — so the persona is the whole question.
    ///
    /// **Publish left this population in stage 3b Task 5** (spec §4's "—" row):
    /// its centre is the book, so it acts on a research subject in neither
    /// column and the item falls through to the manuscript arm. Its own
    /// assertion is `PublishPreviewCentreTests
    /// .test_publishNoLongerTakesTheCentreForAResearchSubject`; the exclusion is
    /// written as the predicate rather than as a name so a fifth persona whose
    /// centre is a book joins it by construction.
    func test_aResearchSubjectTakesTheCentreInEveryPersonaThatCentresADocument() {
        for persona in Persona.allCases
        where persona != .plan && !persona.previewsThePublishedBook {
            XCTAssertEqual(
                ProjectWindow.researchSubjectPlacement(
                    persona: persona, subject: .research("r1")),
                .takesTheCentre("r1"),
                "\(persona) has no research surface of its own in the centre, "
                + "so the window's subject is what that column is about")
        }
    }

    /// **Plan previews beside the board and never gives the centre away.**
    ///
    /// This was two tests, because Plan was two states: its Structure tab
    /// mounted a real tree whose rows write the subject and previewed beside the
    /// board, while its Canvas tab mounted the old research pane — which wrote
    /// its own private selection and never the subject — so a research subject
    /// reaching the right column THERE replaced the region, scrap, line and item
    /// inspectors with nothing in the window able to clear it. It persisted
    /// through `UIState` and Plan landed on that tab, so a relaunch reopened
    /// into it. That is the 2a Critical, and Task 7 removed the state rather
    /// than the guard: Plan has one left column, it is the tree, and the tree
    /// gives the column back
    /// (`ProjectSubjectReachabilityTests.test_everyWindowStateThatLetsAResearchSubjectStandCanAlsoClearIt`).
    func test_planPreviewsBesideTheCanvasAndNeverGivesTheBoardAway() {
        XCTAssertEqual(
            ProjectWindow.researchSubjectPlacement(
                persona: .plan, subject: .research("r1")),
            .besideTheCanvas("r1"),
            "Plan draws the canvas in the centre — a research click must not "
            + "swap it out and take the writer's camera with it — and the "
            + "tree's own rows are what give the right column back")
    }

    /// **The containment claim that outlived two deleted guards.**
    ///
    /// `keepsItsOwnResearchSelection` (deleted in stage 2b Task 6) asked whether
    /// a centre was already about a research item; the trap guard beside it —
    /// can the writer get back out — was strictly wider, which is the whole
    /// warrant for deleting the narrow one, because a narrower guard nested
    /// inside a wider one never decides a case on its own. The wide one went in
    /// Task 7 with the enum it was asked of. What both were protecting survives:
    /// **Plan's centre is never handed over.**
    func test_planNeverHandsItsCentreToAResearchSubject() {
        XCTAssertNil(
            ProjectWindow.researchSubjectPlacement(
                persona: .plan, subject: .research("r1")).centreItemID,
            "the board is Plan's centre column; a research item may sit beside "
            + "it and never in it")
        XCTAssertNotNil(
            ProjectWindow.researchSubjectPlacement(
                persona: .author, subject: .research("r1")).centreItemID,
            "the control: somebody does hand the centre over, or the assertion "
            + "above is true of a function that never takes a centre at all")
    }

    /// A subject that is not research leaves every persona's columns alone.
    func test_aSubjectThatIsNotResearchLeavesEveryPersonaAlone() {
        for persona in Persona.allCases {
            for subject: BinderSubject? in [nil, .project, .item("ch-1")] {
                XCTAssertEqual(
                    ProjectWindow.researchSubjectPlacement(
                        persona: persona, subject: subject),
                    .nothingMoves,
                    "\(persona) with \(String(describing: subject))")
            }
        }
    }

    /// **The right column previews exactly when the centre is not showing the
    /// item** — the one sentence both columns are derived from, asserted over
    /// every case rather than trusted at each call site.
    func test_thePreviewIsShownExactlyWhereTheCentreIsNotShowingTheItem() {
        let placements: [ProjectWindow.ResearchSubjectPlacement] =
            [.takesTheCentre("r1"), .besideTheCanvas("r1"), .nothingMoves]
        for placement in placements {
            XCTAssertEqual(
                placement.previewsInTheRightColumn,
                placement.inspectedItemID != nil && placement.centreItemID == nil,
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
            id: card.id, in: store.manifest.research)

        XCTAssertEqual(route, .paletteCard(card.id))
    }

    func test_aTextNoteRoutesToTheNoteEditorWithItsPath() async throws {
        let store = try await novel(notes: ["Ships"], cards: [])
        let note = try XCTUnwrap(researchItem(named: "Ships", in: store))
        let path = try XCTUnwrap(note.path)

        XCTAssertEqual(
            ProjectWindow.researchCentreRoute(id: note.id, in: store.manifest.research),
            .note(item: note, path: path))
    }

    /// A kind the writer cannot edit here — a PDF, an image, a link, a group —
    /// is previewed. `ResearchPreview` is the same view the `.research` segment
    /// has always shown for these.
    func test_anUneditableKindRoutesToThePreview() async throws {
        let store = try await novel(notes: [], cards: [])
        let pdf = try await importPDF(named: "Tide tables", into: store)

        XCTAssertEqual(
            ProjectWindow.researchCentreRoute(id: pdf.id, in: store.manifest.research),
            .preview(pdf))
    }

    /// The render-race arm. The sweep lands a dangling id on `.project` before
    /// the routing sees it (Task 2), but a subject and a manifest arriving in
    /// different passes leave a window in which the id names nothing.
    func test_anIdThatNamesNothingRoutesToTheEmptyState() async throws {
        let store = try await novel(notes: ["Ships"], cards: [])

        XCTAssertEqual(
            ProjectWindow.researchCentreRoute(id: "no-such-item",
                                              in: store.manifest.research),
            .missing)
        XCTAssertEqual(
            ProjectWindow.researchCentreRoute(id: nil, in: store.manifest.research),
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
            ProjectWindow.researchCentreRoute(id: note.id, in: store.manifest.research),
            .note(item: note, path: path))
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
        XCTAssertEqual(
            occurrences(of: "ProjectStore.paletteFolderPath", in: source), 1,
            "and the palette-path rule is spelled exactly once, inside "
            + "`researchCentreRoute` — a second copy is the drift with extra "
            + "steps")
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
    /// readings are all about a manuscript document; over a research note the
    /// goal capsule is about something else and the `¶id`/element readouts are
    /// blank. The binder segment alone used to be a complete answer — the
    /// manuscript segment could hold nothing but a document — and stage-2a's
    /// Task 5 is what made it incomplete.
    func test_theManuscriptStatusFooterIsSilentWhenAResearchItemTookTheCentre() {
        for persona in Self.centresThatHoldADocument {
            XCTAssertTrue(
                ProjectWindow.showsStatusFooter(persona: persona,
                                                subject: .item("doc1"),
                                                showsPaletteWall: false,
                                                structure: Self.oneDocument),
                "control: \(persona) over a manuscript document still reports")
            XCTAssertFalse(
                ProjectWindow.showsStatusFooter(persona: persona,
                                                subject: .research("r1"),
                                                showsPaletteWall: false,
                                                structure: Self.oneDocument),
                "\(persona) with a research item in the centre has no document "
                + "for the footer to be about")
        }
        // **The centre still decides FIRST**, and the subject only narrows it —
        // this is never a second answer to what the centre column holds. Since
        // Task 6 the first decision is the persona's, so the loop walks the
        // personas whose centre is not a document at all.
        for persona in Self.centresThatHoldNoDocument {
            XCTAssertFalse(
                ProjectWindow.showsStatusFooter(persona: persona,
                                                subject: .item("doc1"),
                                                showsPaletteWall: false,
                                                structure: Self.oneDocument),
                "\(persona): a document subject cannot conjure a footer over a "
                + "centre column that is not a document")
        }
    }

    /// **The wall term, since Task 8.** Tasks 6 and 7 each recorded the same
    /// gap and left it: since stage 2b Task 5 the palette wall can take the
    /// centre column in Author, Review and Publish
    /// (`showsPaletteWallCentre`), and the footer's gate did not know about
    /// it — so the goal capsule, the live session words and a stale
    /// `¶id`/element readout sat under the wall.
    ///
    /// **The wall never reaches Plan's centre** (`showsPaletteWallCentre`'s own
    /// `persona != .plan` term — Plan's centre is the board), so Plan gets its
    /// own assertion below: the wall flag must be able to flip `true` with no
    /// effect there, or the fact that Author/Review/Publish go silent under it
    /// would be a coincidence about those three rather than about the wall.
    func test_theManuscriptStatusFooterIsSilentUnderThePaletteWall() {
        for persona in [Persona.author, .review, .publish] {
            XCTAssertFalse(
                ProjectWindow.showsStatusFooter(persona: persona,
                                                subject: .item("doc1"),
                                                showsPaletteWall: true,
                                                structure: Self.oneDocument),
                "\(persona): the wall is centred over the document — the "
                + "footer's four readings have nothing under them to report on")
            XCTAssertTrue(
                ProjectWindow.showsStatusFooter(persona: persona,
                                                subject: .item("doc1"),
                                                showsPaletteWall: false,
                                                structure: Self.oneDocument),
                "control: \(persona) with the wall closed still reports")
        }
        XCTAssertFalse(
            ProjectWindow.showsStatusFooter(persona: .plan, subject: .item("doc1"),
                                            showsPaletteWall: true,
                                            structure: Self.oneDocument),
            "Plan never shows the footer regardless — its centre is the board, "
            + "not a document, wall or no wall")
    }

    /// The personas whose centre column IS a manuscript document, and the ones
    /// whose is not — each derived from the rule rather than named, so a fifth
    /// persona joins the loop it belongs to without an edit here.
    static let centresThatHoldADocument: [Persona] =
        Persona.allCases.filter(\.showsManuscriptDocuments)
    static let centresThatHoldNoDocument: [Persona] =
        Persona.allCases.filter { !$0.showsManuscriptDocuments }

    /// The structure the footer's `doc1` subject is looked up in. Since
    /// shell-finish stage 3a Task 2 the footer resolves the subject against the
    /// manifest — a subject that names no document draws the altitude view, and
    /// the footer's four readings have nothing to be about — so a bare id with
    /// no structure behind it would read as dangling and every "control: still
    /// reports" assertion above would be inverted.
    static let oneDocument: [StructureItem] = [
        StructureItem(id: "doc1", title: "Chapter One", type: .document,
                      path: "manuscript/chapter-1.md")
    ]

    /// The anti-vacuity control both loops above need: neither set is empty, so
    /// neither loop is asserting nothing.
    func test_theFooterExclusionIsNeitherEmptyNorEverything() {
        XCTAssertFalse(Self.centresThatHoldNoDocument.isEmpty,
                       "every persona holds a document — the second loop is "
                       + "vacuous")
        XCTAssertFalse(Self.centresThatHoldADocument.isEmpty,
                       "no persona holds a document — the first loop is vacuous")
    }

    // MARK: - Mounted: the note reaches the centre, through each tree

    func test_aNoteSelectedInTheNovelTreeReachesTheCentreAndTheInspector() async throws {
        let store = try await novel(notes: ["Ships"], cards: [])
        let note = try XCTUnwrap(researchItem(named: "Ships", in: store))
        try seedNoteText(Self.noteText, at: note, in: store)

        let mount = try await host(store: store, tree: .binder, persona: .author)
        let table = try XCTUnwrap(firstTableView(in: mount.window))
        await select(row: 1 + store.manifest.structure.count + 1, in: table,
                     until: { mount.probe.subject == .research(note.id) })

        try await assertTheNoteIsInTheCentre(of: mount, note: note)
    }

    func test_aNoteSelectedInTheCollectionTreeReachesTheCentreAndTheInspector() async throws {
        let store = try await collection(pieces: ["One"], notes: ["Ships"], cards: [])
        let note = try XCTUnwrap(researchItem(named: "Ships", in: store))
        try seedNoteText(Self.noteText, at: note, in: store)

        let mount = try await host(store: store, tree: .collection, persona: .author)
        let table = try XCTUnwrap(firstTableView(in: mount.window))
        await select(row: 1 + store.manifest.structure.count + 1, in: table,
                     until: { mount.probe.subject == .research(note.id) })

        try await assertTheNoteIsInTheCentre(of: mount, note: note)
    }

    func test_aNoteSelectedInTheScreenplayTreeReachesTheCentreAndTheInspector() async throws {
        let store = try await screenplay(notes: ["Ships"], cards: [])
        let note = try XCTUnwrap(researchItem(named: "Ships", in: store))
        try seedNoteText(Self.noteText, at: note, in: store)

        let mount = try await host(store: store, tree: .navigator, persona: .author)
        let table = try XCTUnwrap(firstTableView(in: mount.window))
        // project, script, two sluglines, the Research header, then the note.
        await select(row: 5, in: table,
                     until: { mount.probe.subject == .research(note.id) })

        try await assertTheNoteIsInTheCentre(of: mount, note: note)
    }

    /// **Review reaches the same note through the same tree row — locked.**
    /// (shell-finish stage 3b Task 6, Denver's ruling: Review adjudicates and
    /// does not edit research from its own columns.) The routing this file
    /// already pins is untouched — the note still reaches the centre — so this
    /// is the one place a real tree click's result is checked against
    /// `Persona.editsResearchInTheCentre` rather than only against
    /// `ResearchSubjectPlacement`. `ReviewAdjudicationTests` covers the rest of
    /// the contract (the palette card, the wall, the tree's verbs) with a
    /// lighter direct mount; this is the click-to-lock path through production's
    /// own tree.
    func test_aNoteSelectedInReviewReachesTheCentreLocked() async throws {
        let store = try await novel(notes: ["Ships"], cards: [])
        let note = try XCTUnwrap(researchItem(named: "Ships", in: store))
        try seedNoteText(Self.noteText, at: note, in: store)

        let mount = try await host(store: store, tree: .binder, persona: .review)
        let table = try XCTUnwrap(firstTableView(in: mount.window))
        await select(row: 1 + store.manifest.structure.count + 1, in: table,
                     until: { mount.probe.subject == .research(note.id) })

        await pumpUntil(deadline: 5) {
            self.textViews(in: mount.window).contains { $0.string.contains(Self.noteText) }
        }
        let editor = try XCTUnwrap(
            textViews(in: mount.window).first { $0.string.contains(Self.noteText) },
            "Review must still show the note's own text — locked, not hidden")
        XCTAssertEqual(editor.coordinator?.lockEditing, true,
                       "the tree row's click must reach Review's lock, not just the direct mount")
    }

    // MARK: - Mounted: the palette card takes the card editor

    /// The lost-update precedent, on the delivery path: a card row in the tree
    /// is a research subject like any other, and the centre must be the visual
    /// editor rather than a text editor holding the card's source.
    func test_aPaletteCardSelectedInTheTreeMountsTheCardEditorNotTheNoteEditor() async throws {
        let store = try await novel(notes: ["Ships"], cards: ["Harbour"])
        let card = try XCTUnwrap(store.paletteCardItems().first)

        let mount = try await host(store: store, tree: .binder, persona: .author)
        let table = try XCTUnwrap(firstTableView(in: mount.window))
        // the project row, the chapters, Research (header + note), then the
        // Palette header and the card.
        await select(row: 1 + store.manifest.structure.count + 2 + 1, in: table,
                     until: { mount.probe.subject == .research(card.id) })

        XCTAssertEqual(mount.probe.subject, .research(card.id), "precondition")
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

    // MARK: - Mounted: the canvas keeps the centre in Plan

    /// **A research click in Plan previews the item and leaves the board
    /// alone.** Both halves are the assertion: the canvas is not rebuilt (its
    /// `load()` count does not move), and the right column shows the item.
    func test_aResearchClickInPlanPreviewsBesideACanvasThatIsNeverRebuilt() async throws {
        let store = try await novel(notes: [], cards: [])
        let pdf = try await importPDF(named: "Tide tables", into: store)

        let mount = try await host(store: store, tree: .binder, persona: .plan)
        await pumpUntil(deadline: 5) { mount.canvasLoads.count >= 1 }
        let loadsBefore = mount.canvasLoads.count
        XCTAssertGreaterThan(loadsBefore, 0,
                             "precondition: the canvas is the centre column")
        let boardBefore = try XCTUnwrap(canvasViews(in: mount.window).first,
                                        "precondition: the board is mounted")

        let table = try XCTUnwrap(firstTableView(in: mount.window))
        await select(row: 1 + store.manifest.structure.count + 1, in: table,
                     until: { mount.probe.subject == .research(pdf.id) })
        XCTAssertEqual(mount.probe.subject, .research(pdf.id), "precondition")

        await pumpUntil(deadline: 5) { !self.pdfViews(in: mount.window).isEmpty }
        XCTAssertFalse(
            pdfViews(in: mount.window).isEmpty,
            "the right column previews the item — otherwise a research click in "
            + "Plan changes nothing anywhere and the tree's Research section is "
            + "a list that does not do anything")
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

    /// **The canvas inspector is reachable in Plan, and a research subject is
    /// what deliberately replaces it.**
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
    func test_theCanvasInspectorIsReachableInPlanAndAResearchSubjectReplacesIt() async throws {
        let store = try await novel(notes: ["Ships"], cards: [])
        let note = try XCTUnwrap(researchItem(named: "Ships", in: store))

        let model = CanvasModel()
        let mount = try await host(store: store, tree: .binder, persona: .plan,
                                   subject: .project, canvasModel: model)

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
            "the selected region's own name field must be in Plan's right "
            + "column — without it the region, scrap, line and item inspectors "
            + "are unreachable from the one persona that draws the board")

        mount.probe.subject = .research(note.id)
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
    /// The right column is the writer's only view of the item in Plan, and it
    /// mounted `ResearchPreview` for everything — so a card previewed as the raw
    /// markdown of its source file, which is the exact rendering
    /// `researchCentreRoute` was extracted to stop the window showing. The
    /// function existed and this column did not call it.
    func test_aPaletteCardPreviewedBesideTheCanvasIsDrawnAsACard() async throws {
        let store = try await novel(notes: [], cards: ["Harbour"])
        let card = try XCTUnwrap(store.paletteCardItems().first)

        let mount = try await host(store: store, tree: .binder, persona: .plan,
                                   subject: .research(card.id))
        XCTAssertEqual(mount.probe.subject, .research(card.id), "precondition")

        await pumpUntil(deadline: 5) { !self.segmentedControls(in: mount.window).isEmpty }
        XCTAssertFalse(
            segmentedControls(in: mount.window).isEmpty,
            "PaletteCardEditor's Kind picker is a segmented control and nothing "
            + "else in this window mounts one — the card must be drawn as a card "
            + "in the preview half, not as the markdown of its source")
    }

    // MARK: - Shared mounted assertions

    private func assertTheNoteIsInTheCentre(
        of mount: Mount, note: ResearchItem,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        XCTAssertEqual(mount.probe.subject, .research(note.id),
                       "precondition: the tree wrote the subject", file: file, line: line)

        await pumpUntil(deadline: 5) {
            self.textViews(in: mount.window).contains { $0.string.contains(Self.noteText) }
        }
        let editors = textViews(in: mount.window)
        XCTAssertTrue(
            editors.contains { $0.string.contains(Self.noteText) },
            "the note the tree named must be the note in the centre column — "
            + "found \(editors.count) editor(s) holding "
            + "\(editors.map { String($0.string.prefix(40)) })",
            file: file, line: line)

        await pumpUntil(deadline: 5) {
            self.textFields(in: mount.window).contains { $0.stringValue == note.title }
        }
        XCTAssertTrue(
            textFields(in: mount.window).contains { $0.stringValue == note.title },
            "and the right column inspects it — InspectorResearchPanel's Title "
            + "field carries the item's own title",
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
        for title in pieces { _ = try await store.addLoosePiece(title: title, mode: .prose) }
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
        let probe: BinderSubjectProbe
        let canvasLoads: CanvasLoadCounter
    }

    /// - Parameters:
    ///   - subject: the window's subject **before the first render**, for the
    ///     tests about a subject the writer arrives carrying — `UIState` restores
    ///     one on launch, and a persona or segment switch keeps it. Seeded on the
    ///     probe rather than clicked, because the point is that no click in this
    ///     segment could have produced it.
    ///   - canvasModel: the board the centre and the region inspector share.
    ///     Given by a caller that has selected something on it.
    private func host(store: ProjectStore, tree: Tree,
                      persona: Persona,
                      subject: BinderSubject? = nil,
                      canvasModel: CanvasModel = CanvasModel()) async throws -> Mount {
        let probe = BinderSubjectProbe()
        probe.subject = subject
        let counter = CanvasLoadCounter()
        let suite = "research-subject-routing-\(UUID().uuidString)"
        defaultsSuites.append(suite)
        let preferences = UserPreferences(defaults: UserDefaults(suiteName: suite)!)
        let documentStore = try XCTUnwrap(store.documentStore)

        let root = ResearchRoutingProbeView(
            store: store,
            documentStore: documentStore,
            tree: tree,
            persona: persona,
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
/// The tree is production's own (all three hosts), the subject binding is the
/// window's, and both other columns are chosen by the SAME
/// `ProjectWindow.researchSubjectPlacement` value the window's `editorPane` and
/// `inspectorPane` read. Nothing here re-spells the rule — a probe that decided
/// for itself which column gets the item would be testing the probe.
@MainActor
private struct ResearchRoutingProbeView: View {
    let store: ProjectStore
    let documentStore: DocumentStore
    let tree: ResearchSubjectRoutingProbeTree
    let persona: Persona
    let script: FountainScript?
    let documentID: String?
    let probe: BinderSubjectProbe
    let canvasModel: CanvasModel
    let canvasLoads: CanvasLoadCounter

    @State private var renaming: String?
    let treeState = BinderTreeSectionsState()

    private var subject: Binding<BinderSubject?> {
        Binding(get: { probe.subject }, set: { probe.subject = $0 })
    }

    private var placement: ProjectWindow.ResearchSubjectPlacement {
        ProjectWindow.researchSubjectPlacement(persona: persona,
                                               subject: probe.subject)
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
        switch tree {
        case .binder:
            BinderView(store: store, selectedSubject: subject,
                       treeState: treeState)
        case .collection:
            CollectionPiecesPane(store: store, selectedSubject: subject,
                                 renamingItemId: $renaming,
                                 treeState: treeState)
        case .navigator:
            SceneNavigatorPane(store: store, script: script,
                               projectTitle: store.manifest.title,
                               selectedSubject: subject,
                               documentID: documentID,
                               treeState: treeState,
                               onSelect: { _ in })
        }
    }

    @ViewBuilder
    private var centre: some View {
        if let id = placement.centreItemID {
            ResearchSubjectCentre(store: store, documentStore: documentStore,
                                  itemID: id, previewVisible: false,
                                  readOnly: !persona.editsResearchInTheCentre)
        } else if persona.centresTheCanvas {
            CanvasView(model: canvasModel, projectRoot: store.url,
                       paletteSwatchHexes: { canvasLoads.record(); return [] })
        } else {
            Color.clear
        }
    }

    /// **The right column, with production's own fallback.**
    ///
    /// `researchOrSegment` asks the placement first and `inspectorRoute` second,
    /// so where the canvas centres the window the region inspector is what the
    /// column falls back to. Modelling only the research half made the probe
    /// unable to see the failure the final review found: an inspector arm that
    /// is REPLACED looks exactly like one that was never asked for.
    @ViewBuilder
    private var right: some View {
        if let id = placement.inspectedItemID {
            ResearchSubjectInspector(store: store, itemID: id,
                                     showsPreview: placement.previewsInTheRightColumn)
        } else if persona.centresTheCanvas {
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
