import XCTest
import AppKit
import ApplicationServices
import SwiftUI
import Observation
import MaughamCore
@testable import Maugham

/// **The passes board is the Book's Status view** (M3 P1 Task 6; shell p1
/// Task 2 made it a view rather than a cover) — drawn inside the altitude
/// layer of `manuscriptEditor`'s `ZStack`, chosen by the route's `BookView`.
///
/// Two things are under test and they need different instruments:
///
/// - **The rule.** `ProjectWindow.reviewCentreShowsBoard` is a static over
///   `(subject, bookView, structure)`, so the whole truth table is drivable with
///   no window at all — including the row that changed nothing: a chapter
///   open is the chapter.
/// - **The shape.** The board is inside a LAYER, never a new `editorPane` arm, for the
///   reason stage 3a recorded and stage 3b repeated: two ViewBuilder branches
///   are two view identities, and `EditorHost.onDisappear` is `doc.close()` +
///   `documentStore.unregister(path:)` + `loads.abandon()`. The mounted tests
///   count the host's lifetimes across a board ↔ editor ↔ board round trip; the
///   control drives the rejected arm shape through the same trip so the counter
///   is proven able to see a teardown; and the source census at the foot is the
///   bridge from the probe's spelling to production's.
///
/// **Task 6 builds the routing, not the board.** `ReviewBoardPane` is a
/// placeholder until Task 7, so what these tests assert about it is only what
/// the routing turns on — it mounts, it fills the column, it covers the
/// corkboard — never what it draws. `ReviewBoardPaneTests` (Task 7) is the
/// suite about its contents.
@MainActor
final class ReviewBoardRoutingTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        // This suite mounts `EditorHost`, which styles text through production
        // typography (the fontd cold-start window, CLAUDE.md).
        FontWarmup.ensure()
    }

    private var temp: TempDirectory!
    private var windows: [NSWindow] = []
    private var documentStores: [DocumentStore] = []
    private var defaultsSuites: [String] = []

    override func setUp() async throws { temp = TempDirectory() }

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

    // MARK: - The rule

    /// **The whole truth table, in one loop.**
    ///
    /// | `open` | Status | Cards / Outline |
    /// |---|---|---|
    /// | the Book / a Part (or a dangling id) | the BOARD | not the board |
    /// | anything else | not the board | not the board |
    func test_theBoardIsTheStatusViewOfTheBookOrAPartAndNothingElse() {
        for (subject, shape) in ProjectAltitudeCentreTests.notADocument {
            for view in BookView.allCases {
                XCTAssertEqual(
                    ProjectWindow.reviewCentreShowsBoard(
                        subject: SubjectSamples.opened(subject), bookView: view,
                        structure: ProjectAltitudeCentreTests.structure),
                    view == .status,
                    "\(shape) in \(view): the board is the Status view")
            }
        }
        for open in [BinderSubject.item("chapter-1"), .research("r1"), .figure("f1"),
                     .canvas, .inbox, .palette, .edition(language: "es")] {
            XCTAssertFalse(
                ProjectWindow.reviewCentreShowsBoard(
                    subject: SubjectSamples.opened(open), bookView: .status,
                    structure: ProjectAltitudeCentreTests.structure),
                "\(open): a board of chips over a chapter (or anywhere that is "
                + "not the Book) is the defect the book's ruling walked back")
        }
    }

    /// **A research item open never reaches the board** — the arm above takes
    /// it, and the rule refuses it too.
    func test_aResearchItemOpenIsTakenByTheArmAboveAndNeverReachesTheBoard() {
        let subject = SubjectSamples.opened(.research("r1"))
        XCTAssertEqual(ProjectWindow.centreRoute(
            subject: subject, bookView: .status, projectType: .novel,
            structure: ProjectAltitudeCentreTests.structure, preview: .nothingCompiled),
                       .research(id: "r1"))
        XCTAssertFalse(ProjectWindow.reviewCentreShowsBoard(
            subject: subject, bookView: .status,
            structure: ProjectAltitudeCentreTests.structure))
    }

    /// The mounted half: a research item open puts the note in the centre, with
    /// no board over it, whatever the Book's view.
    func test_aResearchItemOpenShowsTheNoteAndNotTheBoard() async throws {
        let store = try await novel()
        let note = try await store.addResearchTextNote(parentId: nil, title: "Ships")
        let mount = try await host(store: store,
                                   subject: SubjectSamples.opened(.research(note.id)))

        await waitOut(0.5)
        XCTAssertNil(boardScroller(in: mount.window),
                     "the research arm above the editor arm took the centre, so "
                     + "no board is drawn. Views: \(viewNames(in: mount.window))")
        XCTAssertNil(altitudeTable(in: mount.window),
                     "…and no corkboard either, for the same reason")
    }

    /// **The rule asks the view question that already exists** — `altitudeView`
    /// — rather than a second document-resolution rule.
    func test_theRuleComposesTheWindowsOwnDocumentQuestion() throws {
        let rule = try SourceTree.declaration(
            named: "static func reviewCentreShowsBoard(", under: "Maugham")
        XCTAssertTrue(rule.contains("altitudeView("), "the rule asks `altitudeView`")
        XCTAssertFalse(rule.contains("selectionIsDocument("),
                       "…and not re-derived from the primitive underneath it, "
                       + "which is how the two would come to disagree")
        XCTAssertFalse(rule.contains("TreeWalk."),
                       "…nor by walking the structure a second time")

        for subject in SubjectSamples.everySubject {
            for view in BookView.allCases {
                XCTAssertEqual(
                    ProjectWindow.reviewCentreShowsBoard(
                        subject: subject, bookView: view,
                        structure: ProjectAltitudeCentreTests.structure),
                    ProjectWindow.altitudeView(
                        subject: subject, bookView: view,
                        structure: ProjectAltitudeCentreTests.structure) == .status,
                    "\(subject.open), \(view): the two must answer together")
            }
        }
    }

    // `test_theBoardsFilesAskThePredicateRatherThanNamingThePersona` and its
    // `== .review` name-gate scanner retired with the personas (shell p1 Task
    // 6): there is no persona left to name, and `NoPersonaCensusTests` covers
    // every production file.

    // MARK: - The status footer

    /// **Why the footer needs no Status clause of its own.** Wherever
    /// `reviewCentreShowsBoard` is true, `open` names no document, so the
    /// footer has already refused. Asserted over the whole product rather than
    /// argued.
    func test_theBoardOnlyEverCoversAltitudeSoTheFooterNeedsNoClauseOfItsOwn() {
        var covered = 0
        for subject in SubjectSamples.everySubject {
            for view in BookView.allCases {
                guard ProjectWindow.reviewCentreShowsBoard(
                    subject: subject, bookView: view,
                    structure: SubjectSamples.structure)
                else { continue }
                covered += 1
                XCTAssertFalse(
                    ProjectWindow.showsStatusFooter(subject: subject,
                                                    structure: SubjectSamples.structure),
                    "\(subject.open): the footer must be silent under the board")
            }
        }
        XCTAssertGreaterThan(covered, 0,
                             "the loop never reached a covered case, so the "
                             + "implication above is vacuously true")
    }

    // MARK: - Mounted: the board takes the centre

    /// **The Book in Status draws the board, in place of the Outline.** It is
    /// the altitude layer's own view, so the outline is not mounted beneath it
    /// and the middle of the column is the board.
    func test_theBookInStatusShowsTheBoardInPlaceOfTheOutline() async throws {
        let store = try await novel()
        let mount = try await host(store: store, subject: .book)

        await pumpUntil(deadline: 5) { self.boardScroller(in: mount.window) != nil }
        let board = try XCTUnwrap(
            boardScroller(in: mount.window),
            "the Book's Status view mounted no board. Views: "
            + "\(viewNames(in: mount.window))")
        XCTAssertNil(altitudeTable(in: mount.window),
                     "Status is a view of the Book, not a cover over the Outline")
        XCTAssertTrue(textViews(in: mount.window).isEmpty,
                      "and no editor is open under it")

        let hit = try middleOfTheColumn(in: mount.window)
        XCTAssertTrue(hit === board || hit.isDescendant(of: board),
                      "the middle of the column hit-tests to \(type(of: hit)), "
                      + "which is not the board")
    }

    /// **A Part in Status shows the board too** — a Part is a small Book.
    func test_aPartInStatusAlsoShowsTheBoard() async throws {
        let store = try await novel()
        let group = try await store.addStructureItem(
            parentId: nil, title: "Part One", kind: .group)
        _ = try await store.addStructureItem(
            parentId: group.id, title: "Inside The Part", kind: .document(.markdown))

        for (subject, shape) in [(SubjectSamples.opened(.item(group.id)), "a Part"),
                                 (WindowSubject.book, "the Book")] {
            let mount = try await host(store: store, subject: subject)
            await pumpUntil(deadline: 5) { self.boardScroller(in: mount.window) != nil }
            XCTAssertNotNil(boardScroller(in: mount.window),
                            "\(shape) in Status is the board. Views: "
                            + "\(viewNames(in: mount.window))")
            XCTAssertTrue(textViews(in: mount.window).isEmpty,
                          "\(shape): and no editor is open behind it")
        }
    }

    /// **A chapter open is the chapter, whatever the Book's view.** A reviewer
    /// with a note to leave needs the prose, and a board over it is the defect
    /// Denver's 2026-08-12 ruling walked back.
    func test_aChapterOpenIsTheEditorAndNothingCoversIt() async throws {
        let store = try await novel()
        let chapter = try Self.firstDocument(in: store)
        let mount = try await host(store: store,
                                   subject: SubjectSamples.opened(.item(chapter.id)))

        await pumpUntil(deadline: 5) { !self.textViews(in: mount.window).isEmpty }
        XCTAssertFalse(textViews(in: mount.window).isEmpty,
                       "the chapter must open. Views: \(viewNames(in: mount.window))")
        XCTAssertNil(boardScroller(in: mount.window),
                     "…and the board must not be drawn over it")
        XCTAssertNil(altitudeTable(in: mount.window),
                     "…nor the corkboard")
    }

    /// **The control that makes the readings above discriminate.** The Book
    /// in Outline is the outline, so the same window with the same subject must
    /// mount no board at all — otherwise `boardScroller` is finding something
    /// every centre column has.
    func test_control_theBookInOutlineMountsNoBoard() async throws {
        let store = try await novel()
        let mount = try await host(store: store, subject: .book, view: .outline)

        await pumpUntil(deadline: 5) { self.altitudeTable(in: mount.window) != nil }
        XCTAssertNotNil(altitudeTable(in: mount.window),
                        "premise: the Book in Outline draws the outline")
        XCTAssertNil(boardScroller(in: mount.window),
                     "the Outline mounted a board — either the view is not "
                     + "asked, or `boardScroller` is reading a view every centre "
                     + "column has. Views: \(viewNames(in: mount.window))")
    }

    // MARK: - Mounted: the host survives the new layer

    /// **`EditorHost` is torn down ZERO times across board ↔ editor ↔ board.**
    ///
    /// The whole reason the board is a layer: a new `editorPane` arm would
    /// unmount the host on every hop, and its `.onDisappear` is `doc.close()` +
    /// `documentStore.unregister(path:)` + `loads.abandon()`. The trip is the
    /// one a reviewer makes all day — the board, a chapter to read, the board
    /// again.
    func test_theBoardEditorBoardRoundTripNeverTearsTheHostDown() async throws {
        let store = try await novel()
        let chapter = try Self.firstDocument(in: store)
        let mount = try await host(store: store, subject: .book)

        await pumpUntil(deadline: 5) {
            self.boardScroller(in: mount.window) != nil
                && mount.hostLife.appearances == 1
        }
        XCTAssertEqual(mount.hostLife.appearances, 1, "premise: the host mounted")
        XCTAssertEqual(mount.hostLife.disappearances, 0, "premise: and is still up")

        // **Wait for the chapter's own surface, not for the board's absence**
        // (the 2026-08-13 lesson, `PublishPreviewCentreTests`' hop): the subject
        // change removes the layer in the render it causes, while the text view
        // arrives only after `EditorHost.onChange(of: selectedItemId)` has
        // awaited `loadDocumentIfNeeded()`. Waiting on the departure and
        // asserting the arrival makes the gap a coin flip decided by how a busy
        // worker's runloop is serviced.
        mount.box.pick(.item(chapter.id), in: store)
        await pumpUntil(deadline: 5) {
            self.boardScroller(in: mount.window) == nil
                && !self.textViews(in: mount.window).isEmpty
        }
        XCTAssertNil(boardScroller(in: mount.window),
                     "the board gives way to the prose")
        XCTAssertFalse(textViews(in: mount.window).isEmpty,
                       "the chapter opened in the host that was already there")
        // Pinned at the hop as well as at the end, so a teardown fails HERE,
        // naming the hop, rather than surfacing later as an empty column that
        // reads like a slow render.
        XCTAssertEqual(mount.hostLife.disappearances, 0,
                       "…the same host, not a fresh one on the chapter")
        XCTAssertEqual(mount.hostLife.appearances, 1,
                       "…and it never re-appeared on the way in")

        mount.box.pick(.project, in: store)
        await pumpUntil(deadline: 5) { self.boardScroller(in: mount.window) != nil }
        XCTAssertNotNil(boardScroller(in: mount.window),
                        "and back up to the board")

        XCTAssertEqual(
            mount.hostLife.disappearances, 0,
            "the host was torn down on a hop between the board and the prose — "
            + "which is `doc.close()`, `unregister(path:)` and `loads.abandon()` "
            + "on the gesture a reviewer makes all day")
        XCTAssertEqual(mount.hostLife.appearances, 1,
                       "…and never re-appeared either, so it is the same host "
                       + "with the same Document")
    }

    /// **The VIEW hop — Status, Outline, Status — tears the host down ZERO
    /// times.** The board and the outline are two views of one layer, so
    /// switching between them only swaps that layer's content.
    func test_aViewHopToTheOutlineAndBackNeverTearsTheHostDown() async throws {
        let store = try await novel()
        let mount = try await host(store: store, subject: .book)

        await pumpUntil(deadline: 5) {
            self.boardScroller(in: mount.window) != nil
                && mount.hostLife.appearances == 1
        }
        XCTAssertNotNil(boardScroller(in: mount.window), "premise: Status shows the board")
        XCTAssertEqual(mount.hostLife.appearances, 1, "premise: the host mounted")

        mount.box.bookView = .outline
        await pumpUntil(deadline: 5) { self.altitudeTable(in: mount.window) != nil }
        XCTAssertNil(boardScroller(in: mount.window), "the Outline replaced the board")
        XCTAssertEqual(mount.hostLife.disappearances, 0,
                       "a view switch must only swap the layer's content, never the host")

        mount.box.bookView = .status
        await pumpUntil(deadline: 5) { self.boardScroller(in: mount.window) != nil }
        XCTAssertNotNil(boardScroller(in: mount.window), "the board is back")
        XCTAssertEqual(mount.hostLife.disappearances, 0)
        XCTAssertEqual(mount.hostLife.appearances, 1,
                       "…and never re-appeared, so it is the same host with the "
                       + "same Document across the whole round trip")
    }

    /// **The control that makes the zero above mean something**: the same hop
    /// through the shape this task rejected — the board as an arm of its own
    /// beside the editor. The counter is the same counter; if it could not see a
    /// teardown, the assertion above would be green over any shape at all.
    func test_control_theBoardAsItsOwnArmTearsTheHostDown() async throws {
        let store = try await novel()
        let chapter = try Self.firstDocument(in: store)
        let mount = try await host(store: store,
                                   subject: SubjectSamples.opened(.item(chapter.id)),
                                   shape: .ownArm)

        await pumpUntil(deadline: 5) { mount.hostLife.appearances == 1 }
        XCTAssertEqual(mount.hostLife.appearances, 1,
                       "premise: the arm shape mounts the host on the chapter")

        mount.box.pick(.project, in: store)
        // Waits on the quantity it asserts, for the reason the layered test
        // records: `.onDisappear` is not guaranteed to have run by the render
        // that puts the board on screen, and a control that can time out early
        // is a control that can stop proving the counter works.
        await pumpUntil(deadline: 5) {
            self.boardScroller(in: mount.window) != nil
                && mount.hostLife.disappearances >= 1
        }
        XCTAssertGreaterThanOrEqual(
            mount.hostLife.disappearances, 1,
            "the arm shape tears the host down on the way to the board — which "
            + "is what the layered shape's zero is measured against, and why "
            + "this control exists rather than a comment saying an arm is worse")
    }

    // MARK: - Mounted: the chip's click is the hop

    /// **A chip click makes the same hop the subject change makes** (M3 P1 Task
    /// 8) — the chapter opens in the host that was already mounted underneath,
    /// nothing is torn down, and the pass the reviewer clicked through is
    /// remembered for that piece.
    ///
    /// Driven as a real click on the mounted chip rather than by moving the
    /// subject: the test above proves the HOP is cheap, and this one proves the
    /// chip is what makes it. Writing `box.subject` from the test would prove
    /// nothing about whether the cell can be reached at all.
    ///
    /// The chip clicked is the SECOND chapter's SECOND pass, so neither id could
    /// be the first of anything — the payload has to have come from the cell.
    func test_aChipClickOpensThatChapterInTheHostAndRemembersThePass() async throws {
        let store = try await novel()
        let documents = TreeWalk.collect(in: store.manifest.structure,
                                         where: { $0.type == .document })
        let second = try XCTUnwrap(documents.dropFirst().first,
                                   "fixture premise: the novel has two chapters")
        let passes = store.manifest.effectiveReviewPasses
        try XCTSkipUnless(passes.count >= 2,
                          "this project offers \(passes.count) passes, too few "
                          + "to ask the question about a second column")
        let mount = try await host(store: store, subject: .book)

        await pumpUntil(deadline: 5) {
            self.boardScroller(in: mount.window) != nil
                && self.orderedChips(in: mount.window).count >= documents.count * passes.count
        }
        let chips = orderedChips(in: mount.window)
        XCTAssertEqual(chips.count, documents.count * passes.count,
                       "premise: one chip per (piece × pass)")
        XCTAssertEqual(mount.hostLife.disappearances, 0, "premise: nothing torn down yet")

        await click(chips[passes.count + 1], in: mount.window, until: {
            mount.box.subject.open == .item(second.id)
                && !self.textViews(in: mount.window).isEmpty
        })

        XCTAssertEqual(mount.box.subject.open, .item(second.id),
                       "the click must open the piece the chip is drawn for")
        XCTAssertEqual(
            documentStores.last?.uiState.activePassMemory.activePass(forPiece: second.id),
            passes[1].id,
            "…and record the pass it was clicked through, so the piece opens "
            + "on it next time")
        XCTAssertFalse(textViews(in: mount.window).isEmpty,
                       "the chapter opened in the centre column")
        XCTAssertEqual(mount.hostLife.disappearances, 0,
                       "…in the host that was mounted underneath the board all "
                       + "along — a click that tore it down would be `doc.close()` "
                       + "and `loads.abandon()` on the reviewer's commonest gesture")
        XCTAssertEqual(mount.hostLife.appearances, 1)
        XCTAssertEqual(mount.box.bookView, .status,
                       "and the board moved no view: going back up to the Book "
                       + "lands on Status where the reviewer left it")
    }

    /// **A verb's write reaches the manifest, and the board redraws on it.**
    ///
    /// The menu itself is headless-unreachable (`ReviewBoardChipVerbs`' own doc
    /// comment), so the verb is built here in the production shape —
    /// `onSetState` → `store.setPassState` — and pressed. What that proves that
    /// `ProjectStoreInspectorTests` does not: the board is fed the manifest's
    /// LIVE values at the mount, so a ruling made from it is visible on it
    /// without a reload. A board handed a snapshot would persist the write and
    /// go on showing the old chip.
    func test_aVerbsWritePersistsAndTheBoardRedrawsOnIt() async throws {
        let store = try await novel()
        let chapter = try Self.firstDocument(in: store)
        let pass = try XCTUnwrap(store.manifest.effectiveReviewPasses.first)
        let mount = try await host(store: store, subject: .book)
        await pumpUntil(deadline: 5) { self.boardScroller(in: mount.window) != nil }

        let before = try axChipLabels(in: mount.window)
        try XCTSkipUnless(!before.isEmpty,
                          "no assistive client could attach, so the redraw "
                          + "cannot be read here (InspectorIntentAffordanceTests' "
                          + "rule)")
        let untouched = "\(chapter.title) — \(pass.name): \(PassLadder.untouchedTitle)"
        let done = "\(chapter.title) — \(pass.name): \(PassLadder.doneTitle)"
        XCTAssertTrue(before.contains(untouched),
                      "premise: the cell starts untouched. Published: \(before.sorted())")

        let verbs = ReviewBoardChipVerbs(
            onSetState: { piece, passId, state in
                Task { try? await store.setPassState(id: piece, passId: passId, state) }
            },
            // This test is about a RULING redrawing its chip; a round is the
            // other half of the menu and belongs to the window (M4 P2 Task 4).
            onRunRound: { _, _ in XCTFail("a ruling must not ask for a round") })
        let doneVerb = try XCTUnwrap(
            verbs.chipMenuItems(for: chapter.id, passId: pass.id, current: nil)
                .first { $0.state == .done })
        doneVerb.perform()

        await pumpUntil(deadline: 5) {
            (try? self.axChipLabels(in: mount.window))?.contains(done) == true
        }
        XCTAssertEqual(
            store.manifest.structure.first { $0.id == chapter.id }?.passStates?[pass.id],
            .done,
            "the verb's write must reach the manifest through the store")
        let after = try axChipLabels(in: mount.window)
        XCTAssertTrue(after.contains(done),
                      "…and the chip must redraw on it without a reload. "
                      + "Published: \(after.sorted())")
        XCTAssertFalse(after.contains(untouched),
                       "…and stop saying the old state")
    }

    // MARK: - The shape of the mount, in production

    /// **The bridge from the probe's spelling to the window's.** The mounted
    /// tests drive a probe that takes every routing decision from production's
    /// own statics, but the SHAPE is the probe's own and a probe cannot vouch
    /// for it. This reads the real `manuscriptEditor` and `statusBoard`.
    func test_theBoardIsTheAltitudeLayersStatusViewAndNotAnArmOrACover() throws {
        let arm = try SourceTree.declaration(
            named: "func manuscriptEditor(", under: "Maugham")

        // Still one stack with the host mounted unconditionally underneath and
        // altitude over it — and the board nowhere in the stack but the
        // altitude layer's Status view, placed by `ProjectAltitudePane`.
        XCTAssertEqual(CentreRouteSource.stackFaults(in: arm), [])
        XCTAssertTrue(arm.contains("statusBoard("),
                      "the altitude layer hands the pane its Status view")
        let route = try CentreRouteSource.rule()
        XCTAssertTrue(route.contains("altitudeView("),
                      "the route asks the ONE named rule for the Book's view")
        XCTAssertEqual(
            ProjectWindow.centreRoute(
                subject: .book, bookView: .status, projectType: .novel,
                structure: ProjectAltitudeCentreTests.structure, preview: .nothingCompiled),
            .editor(altitude: .status, cover: nil),
            "Status is the altitude layer's view, never a cover")

        // Counted as CODE across every view: one mount for the board.
        XCTAssertEqual(
            try SourceTree.viewMounts(of: "ReviewBoardPane("), 1,
            "one mount for the board, the Book's Status view. A second is a "
            + "surface nobody decided to add")
        XCTAssertEqual(
            try SourceTree.viewMounts(of: "manuscriptEditor("), 2,
            "the declaration and exactly ONE call — `editorPane`'s `.editor` arm")
    }

    /// The control for the scan above: `declaration(named:)` must BOUND the text
    /// it reads to the one member, or every assertion in it is really about the
    /// whole file and cannot fail. `CanvasView(` is mounted in this same type
    /// (`CentreColumn`), one member down, and must not be visible from inside
    /// the editor arm.
    func test_theArmScanReadsTheArmAndNotTheWholeFile() throws {
        let source = try SourceTree.sourceOfType("CentreColumn", under: ["Maugham"])
        let arm = try SourceTree.declaration(
            named: "func manuscriptEditor(", under: "Maugham")
        XCTAssertTrue(source.contains("CanvasView("),
                      "premise: the file really does mount the canvas")
        XCTAssertFalse(arm.contains("CanvasView("),
                       "…and the scan above cannot see it, so what it asserts "
                       + "is about the editor arm rather than about the file")
    }

    /// **The planted control for the lookups above** (foundations plan 2): a
    /// `ProjectWindow` struct in one file and the editor arm in an
    /// `extension ProjectWindow` in another. The arm is found by symbol across
    /// the extension and bounded to itself.
    func test_theLookupsFindTheArmAcrossAnExtension() throws {
        let base = try SourceTree.plantedTree([
            "Maugham/Views/ProjectWindow.swift": """
            struct ProjectWindow: View {
                var body: some View { CanvasView() }
            }
            """,
            "Maugham/Views/ProjectWindow+Editor.swift": """
            extension ProjectWindow {
                private func manuscriptEditor(store: ProjectStore) -> some View {
                    ZStack { EditorHost(); ReviewBoardPane() }
                }
                private func canvasArm() -> some View { CanvasView() }
            }
            """,
        ])
        let arm = try SourceTree.declaration(
            named: "func manuscriptEditor(", under: "Maugham", base: base)
        XCTAssertTrue(arm.contains("ReviewBoardPane("), "the arm is found in the extension")
        XCTAssertFalse(arm.contains("CanvasView("), "…and bounded to itself")
    }

    /// **What the production mount's chips are wired TO** (M3 P1 Task 8).
    ///
    /// The mounted tests above drive the probe, and the probe's closures are the
    /// probe's own — so this reads the real call's argument list, bounded to it,
    /// and checks the three facts that make a chip click the hop it is: the
    /// window's SUBJECT moves, the pass is recorded, and the ruling goes through
    /// the store. Plus the ejection trap's other half: the board's closures do
    /// not move the Book's view.
    func test_theBoardsChipsAreWiredToTheWindowsSubjectAndTheStore() throws {
        let arm = try SourceTree.declaration(
            named: "func statusBoard(", under: "Maugham")
        let call = try XCTUnwrap(Self.argumentList(after: "ReviewBoardPane(", in: arm),
                                 "the board's mount must still be a call with "
                                 + "arguments this scan can read")
        // Comment lines dropped before the forbidden-pattern half: the mount's
        // own comment explains at length what is NOT written there,
        // and a scan that could not tell the explanation from the act would be
        // a census that fires on its own documentation.
        let code = SourceScan.codeLines(of: call).joined(separator: "\n")

        for expected in ["onNavigate:", "navigate(to: .item(",
                         "recordActivePass(", "onSetState:",
                         "store.setPassState("] {
            XCTAssertTrue(code.contains(expected),
                          "the board's mount does not pass `\(expected)`")
        }
        // One hop out (foundations plan 4 Task 4): the mount lives in
        // `CentreColumn`, whose `recordActivePass` is a closure the window
        // hands it — and the window must hand it its ONE writer.
        XCTAssertTrue(
            try CentreRouteSource.windowArgument("recordActivePass")?
                .contains("recordActivePass(forPiece:") == true,
            "the window must hand the centre column its one `ActivePassMemory` "
            + "writer, `recordActivePass(forPiece:passId:)`")
        XCTAssertFalse(
            code.contains("bookView"),
            "the board's own closures move the Book's view. "
            + "The board is a view of the Book, never a thing that decides what "
            + "the window shows")
    }

    /// **What the open-notes count is wired TO** (M3 P2 Task 9) — the other
    /// half of the mount, and a different verb from the chip's.
    ///
    /// A chip click TRAVELS: opening the chapter is what a chip means, so it
    /// writes the subject. A count click does not — it widens the QUEUE in the
    /// right column and points it at the piece, leaving the board exactly where
    /// it was, because a writer scanning where the feedback piled up is reading
    /// the whole column and must not lose it to the first number they press.
    /// So the closure writes three things (the pane's visibility, the segment,
    /// the scope) and not the subject.
    func test_theCountIsWiredToTheQueueAndDoesNotMoveTheSubject() throws {
        let arm = try SourceTree.declaration(
            named: "func statusBoard(", under: "Maugham")
        let call = try XCTUnwrap(Self.argumentList(after: "ReviewBoardPane(", in: arm))
        let code = SourceScan.codeLines(of: call).joined(separator: "\n")
        let closure = try XCTUnwrap(
            Self.closureBody(after: "onOpenNotes: { pieceId in", in: code),
            "the mount must still wire `onOpenNotes` as a closure this scan "
            + "can read")

        for expected in ["showInspector = true",
                         "detailSegment = .resolve",
                         "resolveRequest = .focus(groupOwnerId: pieceId)"] {
            XCTAssertTrue(closure.contains(expected),
                          "the count's closure does not `\(expected)` — the "
                          + "click has to land the writer IN the queue, in "
                          + "project scope, at the piece they pressed")
        }
        // The control for the two refusals below: the mount's OTHER closure
        // does write the subject, one argument away, so a scan that ran past
        // its own braces would find it and this test could not fail.
        XCTAssertTrue(code.contains("navigate(to: .item("),
                      "premise: the chip's closure, in the same call, travels")
        XCTAssertFalse(
            closure.contains("selectedSubject") || closure.contains("navigate(")
                || closure.contains("subject ="),
            "the count click writes the window's SUBJECT, so pressing a number "
            + "on the board throws the board away — that is the chip's verb, "
            + "not this one")

        // The counts themselves are VALUES, computed off the body path.
        for expected in ["openNotes: openNotesCounts",
                         "unreadableDocIds: openNotesUnreadable"] {
            XCTAssertTrue(code.contains(expected),
                          "the mount must pass `\(expected)` — a store read "
                          + "here would be a project-wide walk per redraw")
        }
    }

    /// **The count is refreshed off the body path, and by the event.**
    ///
    /// This is P1's deferral honoured: the board's body must never ask a store
    /// how many notes a piece has, because that walk opens every document in
    /// the project and the body runs once per row. The one writer is
    /// `refreshOpenNotes`, and the two things that call it are the board's own
    /// `.task` and `.maughamAnnotationsChanged` — the second being what makes a
    /// closed piece's synced-in note reach the number on screen.
    func test_theCountsAreRecomputedOffTheBodyPathAndOnTheEvent() throws {
        // That the board recounts on appear and on the event:
        // `WiringCensusTests`' entry for `manuscriptEditor`.
        let refresh = try SourceTree.declaration(
            named: "func refreshOpenNotes(", under: "Maugham")
        XCTAssertEqual(
            Self.occurrences(of: "listAnnotationsAcrossProject()", in: refresh), 1,
            "ONE walk per refresh: the aggregation is cached, but its cache key "
            + "stats every closed document's op-log files, so reading it twice "
            + "for the two halves of one refresh pays that cost twice "
            + "(`openNotesSummaries(in:)` takes the snapshot for this reason)")

        // And the board's own file still cannot reach a store — the census in
        // `ReviewBoardPaneTests` says so for the pane; this says the count did
        // not arrive by giving it one.
        // Code lines only: the pane's doc comment names the aggregation to say
        // where the numbers come from, and a scan that could not tell the
        // explanation from the act would fire on its own documentation.
        let pane = SourceScan.codeLines(
            of: try Self.source(of: "Views/Review/ReviewBoardPane.swift"))
        XCTAssertFalse(pane.contains { $0.contains("openNotesSummaries") },
                       "the pane must not derive the counts itself")
    }

    /// The control for the scan above: `argumentList(after:)` must stop at the
    /// call's own closing paren. The `.task` that recounts is chained after the
    /// call, in the same declaration, and must not be visible from inside the
    /// board's arguments — or the scan is really reading the whole declaration
    /// and cannot fail.
    func test_theBoardsArgumentScanStopsAtItsOwnCall() throws {
        let arm = try SourceTree.declaration(
            named: "func statusBoard(", under: "Maugham")
        let call = try XCTUnwrap(Self.argumentList(after: "ReviewBoardPane(", in: arm))

        XCTAssertTrue(arm.contains("refreshOpenNotes(store:"),
                      "premise: the declaration really does recount after the call")
        XCTAssertFalse(call.contains("refreshOpenNotes(store:"),
                       "the board's argument scan ran past its own call")
    }

    // MARK: - Hosting

    private struct Mount {
        let window: NSWindow
        let box: ReviewCentreProbeBox
        let hostLife: EditorHostLifeCounter
    }

    /// The centre column alone, wired the way `editorPane` wires it: every
    /// routing decision below the mount comes from production's own statics, and
    /// the subject is held outside the view so a test can move it without a tree.
    private func host(store: ProjectStore,
                      subject: WindowSubject = .book,
                      view: BookView = .status,
                      shape: ReviewCentreProbeView.Shape = .layered)
    async throws -> Mount {
        let documentStore = try await DocumentStore.open(url: store.url)
        store.documentStore = documentStore
        documentStores.append(documentStore)

        let box = ReviewCentreProbeBox(subject: subject, bookView: view)
        let life = EditorHostLifeCounter()
        // `EditorHost` reads `UserPreferences` out of the environment, and a
        // missing environment value is a trap in SwiftUI's own accessor rather
        // than a nil — the whole test process goes down. Its own defaults suite,
        // so nothing here reads or writes the developer's.
        let suite = "review-board-routing-\(UUID().uuidString)"
        defaultsSuites.append(suite)
        let preferences = UserPreferences(defaults: UserDefaults(suiteName: suite)!)
        let root = ReviewCentreProbeView(
            store: store, documentStore: documentStore, box: box,
            hostLife: life, shape: shape, canvasModel: CanvasModel())
            .environment(preferences)

        let window = TestWindow.mount(AnyView(root),
                                      size: CGSize(width: 900, height: 700),
                                      as: SilentTestWindow.self)
        windows.append(window)
        pump(0.1)
        return Mount(window: window, box: box, hostLife: life)
    }

    // MARK: - Reading the mounted window

    /// **The board's own scroll view.**
    ///
    /// Read STRUCTURALLY rather than by class name: an `NSScrollView` in the
    /// window that is neither a table's (the altitude view's, and the tree's if
    /// a caller ever mounts one) nor the editor's. Measured on this SDK, the
    /// three are three different classes — `HostingScrollView`,
    /// `ListCoreScrollView` and a plain `NSScrollView` — and keying on the first
    /// of those names would be a reading Task 7 could break by changing the
    /// pane's container from a `ScrollView` to a `List`. What Task 7 cannot
    /// change is that the board is a scrolling surface of its own that holds
    /// neither the corkboard's table nor the writer's text.
    ///
    /// `test_control_theBookInOutlineMountsNoBoard` is
    /// what says this reading discriminates at all.
    private func boardScroller(in window: NSWindow) -> NSScrollView? {
        collect(NSScrollView.self, in: window).first { scroller in
            var tables: [NSTableView] = []
            var texts: [MaughamTextView] = []
            collect(NSTableView.self, in: scroller, into: &tables)
            collect(MaughamTextView.self, in: scroller, into: &texts)
            return tables.isEmpty && texts.isEmpty
        }
    }

    /// The altitude view in its table layout. The probe hosts the centre column
    /// only, so this is the window's one table.
    private func altitudeTable(in window: NSWindow) -> NSTableView? {
        collect(NSTableView.self, in: window).first
    }

    /// **The board's chips, in the order a reviewer reads them** — down the
    /// rows, then across the passes.
    ///
    /// A SwiftUI `Button` mounts no `NSButton` on this SDK; what it leaves is a
    /// focus-ring container at the frame the layout gave it
    /// (`ReviewBoardPaneTests`' class doc records the measurement). Scoped to
    /// the board's own scroller rather than the window, because the altitude
    /// view underneath carries buttons of its own — the corkboard's cards are
    /// focus rings too, and counting the window's would mix the two layers.
    private func orderedChips(in window: NSWindow) -> [NSView] {
        guard let scroller = boardScroller(in: window) else { return [] }
        var rings: [NSView] = []
        collect(NSView.self, in: scroller, into: &rings)
        return rings
            .filter { String(describing: type(of: $0)).contains("FocusRingView") }
            .map { (view: $0, frame: $0.convert($0.bounds, to: scroller)) }
            .sorted { a, b in
                if abs(a.frame.midY - b.frame.midY) > 1 { return a.frame.midY < b.frame.midY }
                return a.frame.minX < b.frame.minX
            }
            .map(\.view)
    }

    /// A real click at the centre of a view — down and up through the window, so
    /// the `Button` gets its chance exactly as it does under a mouse
    /// (`ProjectAltitudeCentreTests`' technique). `until` is the state the
    /// caller's next assertion reads, waited on rather than slept through.
    private func click(_ view: NSView, in window: NSWindow,
                       until settled: @escaping () -> Bool) async {
        let centre = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        let inWindow = view.convert(centre, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(
                with: type, location: inWindow, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0) {
                window.sendEvent(event)
            }
            pump(0.03)
        }
        await pumpUntil(deadline: 5, settled)
    }

    /// What the board's chips are saying aloud — `ReviewBoardPaneTests`'
    /// reading, walked from the window's content view and filtered to the chip's
    /// own label SHAPE (`ReviewBoardChip.label`: piece — pass: state).
    ///
    /// Walked from the top rather than from the board's scroller because
    /// SwiftUI publishes a synthesized element tree hung off the hosting view:
    /// measured here, the scroller's own AX children carry no buttons at all, so
    /// scoping the walk to it returns nothing and the test skips itself for the
    /// wrong reason. The shape filter is what keeps the corkboard mounted
    /// underneath from contributing — its cards publish no pass label.
    ///
    /// Empty when no assistive client can attach, which callers skip on by name
    /// rather than fail.
    private func axChipLabels(in window: NSWindow) throws -> [String] {
        var role: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            AXUIElementCreateApplication(getpid()), kAXRoleAttribute as CFString, &role)
        guard error == .success, role != nil else { return [] }
        guard let root = window.contentView else { return [] }
        let states = [PassLadder.untouchedTitle, PassLadder.inProgressTitle,
                      PassLadder.doneTitle, PassLadder.skipTitle]
        return Self.axElements(under: root)
            .filter { (Self.axAttribute($0, "accessibilityRole") as? String) == "AXButton" }
            .compactMap { Self.axAttribute($0, "accessibilityLabel") as? String }
            .filter { label in
                label.contains(" \u{2014} ") && states.contains { label.hasSuffix(": \($0)") }
            }
    }

    private static func axAttribute(_ element: AnyObject, _ attribute: String) -> Any? {
        guard let object = element as? NSObject,
              object.responds(to: NSSelectorFromString(attribute)) else { return nil }
        return object.value(forKey: attribute)
    }

    private static func axElements(under root: AnyObject, depth: Int = 0) -> [AnyObject] {
        guard depth < 40 else { return [] }
        let children = axAttribute(root, "accessibilityChildren") as? [AnyObject] ?? []
        return [root] + children.flatMap { axElements(under: $0, depth: depth + 1) }
    }

    private func textViews(in window: NSWindow) -> [MaughamTextView] {
        collect(MaughamTextView.self, in: window)
    }

    private func middleOfTheColumn(in window: NSWindow) throws -> NSView {
        let content = try XCTUnwrap(window.contentView)
        // The premise, read off the window this display actually granted rather
        // than the one asked for: `NSWindow` clamps to the screen, and CI's is
        // narrower than this Mac's. A column too small to have a middle worth
        // asking about is a display that cannot afford the question.
        try XCTSkipUnless(
            content.bounds.width >= 300 && content.bounds.height >= 300,
            "this display mounted a \(content.bounds.size) centre column")
        let middle = NSPoint(x: content.bounds.midX, y: content.bounds.midY)
        return try XCTUnwrap(content.hitTest(content.convert(middle, to: nil)),
                             "nothing at all at the middle of the column")
    }

    /// For a failure message that says what DID mount rather than only what did
    /// not — the difference between a signal that moved and an arm never taken.
    private func viewNames(in window: NSWindow) -> [String] {
        collect(NSView.self, in: window).map { String(describing: type(of: $0)) }
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

    // MARK: - Fixtures on disk

    private func novel() async throws -> ProjectStore {
        let url = try await ProjectFactory.createNovelProject(
            named: "Board-\(UUID().uuidString.prefix(6))", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        _ = try await store.addStructureItem(
            parentId: nil, title: "Chapter Two", kind: .document(.markdown))
        for item in TreeWalk.collect(in: store.manifest.structure,
                                     where: { $0.type == .document }) {
            guard let path = item.path else { continue }
            try "The chapter titled \(item.title), and nothing else at all.\n"
                .write(to: store.url.appendingPathComponent(path),
                       atomically: true, encoding: .utf8)
        }
        await store.wordCountPopulationTask?.value
        return store
    }

    private static func firstDocument(in store: ProjectStore) throws -> StructureItem {
        try XCTUnwrap(
            TreeWalk.first(in: store.manifest.structure, where: { $0.type == .document }),
            "fixture precondition: a novel opens with a chapter")
    }

    // MARK: - Reading the source

    private static func source(of relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MaughamTests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Maugham", isDirectory: true)
        return try String(contentsOf: root.appendingPathComponent(relativePath),
                          encoding: .utf8)
    }

    /// A member declaration, from its opening line to the closing brace at member
    /// indentation — bounded, or a scan over it is really a scan over the rest of
    /// the file (see the control above).
    private static func declaration(named header: String, in source: String) -> String? {
        guard let start = source.range(of: header) else { return nil }
        let rest = source[start.lowerBound...]
        guard let end = rest.range(of: "\n    }\n") else { return String(rest) }
        return String(rest[..<end.upperBound])
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    /// One call's argument list, from `opener` to its own balanced close paren.
    /// Bounded for the reason `declaration(named:)` is: a scan that ran to the
    /// end of the arm would be asserting about every layer in the stack while
    /// claiming to be about one of them.
    /// One CLOSURE's body, from `opener` (which must end just past its opening
    /// brace) to the matching close. `argumentList` cannot do this job: it
    /// counts parens, and inside an argument list already stripped of its own
    /// it would run to the end and quietly assert about the sibling closures —
    /// which is exactly where `selectedSubject` and the persona comment live.
    private static func closureBody(after opener: String, in source: String) -> String? {
        guard let start = source.range(of: opener) else { return nil }
        var depth = 1
        var index = start.upperBound
        while index < source.endIndex, depth > 0 {
            if source[index] == "{" { depth += 1 } else if source[index] == "}" { depth -= 1 }
            index = source.index(after: index)
        }
        return String(source[start.upperBound..<index])
    }

    private static func argumentList(after opener: String, in source: String) -> String? {
        guard let start = source.range(of: opener) else { return nil }
        var depth = 1
        var index = start.upperBound
        while index < source.endIndex, depth > 0 {
            if source[index] == "(" { depth += 1 } else if source[index] == ")" { depth -= 1 }
            index = source.index(after: index)
        }
        return String(source[start.upperBound..<index])
    }
}

// MARK: - Probes

/// The window state the centre column reads, held outside the view so a test can
/// move the subject and the Book's view the way the window does.
@Observable
@MainActor
final class ReviewCentreProbeBox {
    var subject: WindowSubject
    var bookView: BookView
    /// Pieces whose open-notes count was clicked (M3 P2 Task 9).
    var openedNotesFor: [String] = []

    init(subject: WindowSubject, bookView: BookView = .status) {
        self.subject = subject
        self.bookView = bookView
    }

    /// What a card, a row or a chip writes, through the window's own
    /// `ClickRule.navigate`.
    func pick(_ clicked: BinderSubject, in store: ProjectStore) {
        subject = ClickRule.navigate(to: clicked, current: subject,
                                          structure: store.manifest.structure,
                                          projectType: store.manifest.type)
    }
}

/// **The centre column, wired the way `editorPane` wires it** — one switch over
/// production's own `ProjectWindow.centreRoute`, in its case order, rather than
/// decisions re-spelled here. A probe that decided for itself which arm applies
/// would be testing the probe.
///
/// What it spells for itself is the SHAPE of the last arm, which is the thing
/// under test and cannot be reached from outside `ProjectWindow`. Hence two
/// cases: `.layered` is what production does (the board as the altitude
/// layer's Status view), and `.ownArm` is the rejected shape, driven by the
/// control test so the lifetime counter is proven able to see a teardown.
@MainActor
struct ReviewCentreProbeView: View {
    enum Shape { case layered, ownArm }

    let store: ProjectStore
    let documentStore: DocumentStore
    let box: ReviewCentreProbeBox
    let hostLife: EditorHostLifeCounter
    let shape: Shape
    let canvasModel: CanvasModel

    @State private var control = EditorControl()
    @State private var referenceIndex = ReferenceIndexHost()

    private var subject: Binding<BinderSubject?> {
        Binding(
            get: { box.subject.beside?.treeSubject ?? box.subject.faces },
            set: { box.pick($0 ?? .project, in: store) })
    }

    private var bookView: Binding<BookView> {
        Binding(get: { box.bookView }, set: { box.bookView = $0 })
    }

    var body: some View {
        centre.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var centre: some View {
        switch ProjectWindow.centreRoute(
            subject: box.subject, bookView: box.bookView,
            projectType: store.manifest.type, structure: store.manifest.structure,
            preview: .nothingCompiled) {
        case .paletteWall:
            EmptyView()
        case .research(let id):
            ResearchSubjectCentre(store: store, documentStore: documentStore,
                                  itemID: id, previewVisible: false, readOnly: false)
        case .figure:
            EmptyView()   // the probe's subjects are never figures
        case .canvas:
            CanvasView(model: canvasModel, projectRoot: store.url,
                       paletteSwatchHexes: { [] })
        case .reference(let piece):
            ReferencePlaceholderCard(piece: piece, onOpen: {})
        case .editor(let altitude, _):
            manuscriptCentre(altitude: altitude)
        case .inbox:
            EmptyView()
        }
    }

    @ViewBuilder
    private func manuscriptCentre(altitude: BookView?) -> some View {
        switch shape {
        case .layered:
            ZStack {
                editor
                if let altitude { self.altitude(altitude) }
            }
        case .ownArm:
            if altitude == .status {
                board(structure: store.manifest.structure)
            } else if let altitude {
                self.altitude(altitude)
            } else {
                editor
            }
        }
    }

    private var editor: some View {
        EditorHost(store: store, documentStore: documentStore,
                   selectedItemId: box.subject.open.itemID, control: control,
                   referenceIndex: referenceIndex)
            .onAppear { hostLife.appeared() }
            .onDisappear { hostLife.disappeared() }
    }

    private func altitude(_ altitude: BookView) -> some View {
        let scope = ProjectWindow.altitudeScope(open: box.subject.open,
                                                structure: store.manifest.structure,
                                                bookTitle: store.manifest.title)
        return ProjectAltitudePane(store: store, view: altitude, bookView: bookView,
                                   selectedSubject: subject, title: scope.title,
                                   structure: scope.structure) {
            board(structure: scope.structure)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// **Wired the way the production mount is wired** (Task 8): a chip click
    /// opens the piece through the click rule and records the pass, and a menu
    /// verb writes through the store. The probe cannot vouch for production's
    /// own closures — those are read off `statusBoard`'s text by
    /// `test_theBoardsChipsAreWiredToTheWindowsSubjectAndTheStore` — but it can
    /// carry what a click DOES through a real mounted board.
    private func board(structure: [StructureItem]) -> some View {
        ReviewBoardPane(
            title: store.manifest.title,
            structure: structure,
            passes: store.manifest.effectiveReviewPasses,
            openNotes: [:],
            unreadableDocIds: [],
            onOpenNotes: { box.openedNotesFor.append($0) },
            onNavigate: { pieceId, passId in
                box.pick(.item(pieceId), in: store)
                documentStore.updateUIState {
                    $0.activePassMemory.record(piece: pieceId, passId: passId)
                }
            },
            onSetState: { pieceId, passId, state in
                Task { try? await store.setPassState(id: pieceId, passId: passId, state) }
            },
            onRunRound: { pieceId, passId in
                box.pick(.item(pieceId), in: store)
                documentStore.updateUIState {
                    $0.activePassMemory.record(piece: pieceId, passId: passId)
                }
            },
            posture: { _ in .author })
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}
