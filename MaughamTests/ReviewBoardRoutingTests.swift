import XCTest
import AppKit
import ApplicationServices
import SwiftUI
import Observation
import MaughamCore
@testable import Maugham

/// **Review's centre column is the passes board** (M3 P1 Task 6) — and it gets
/// there the way Publish's book does: a layer of `manuscriptEditor`'s `ZStack`,
/// gated on a rule that composes the window's ONE document-resolution question.
///
/// Three things are under test and they need different instruments:
///
/// - **The predicate.** `Persona.showsTheReviewBoard` is a fact about a persona,
///   assertable over `Persona.allCases` with nothing mounted.
/// - **The rule.** `ProjectWindow.reviewCentreShowsBoard` is a static over
///   `(persona, subject, structure)`, so the whole truth table is drivable with
///   no window at all — including the row that changed nothing: a chapter
///   subject in Review still opens the chapter.
/// - **The shape.** The board is a LAYER, never a new `editorPane` arm, for the
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

    // MARK: - The predicate

    /// Exactly one persona, and it is the one whose whole job is adjudicating.
    func test_onlyReviewShowsTheBoard() {
        XCTAssertEqual(Persona.allCases.filter(\.showsTheReviewBoard), [.review])
    }

    /// **It is a third independent fact about the centre column, not the
    /// leftover of the other two.**
    ///
    /// Author is the discriminator this app actually ships: its centre is not
    /// the canvas and not the book either, and its project row is the corkboard
    /// — stage 3a's altitude view, untouched by this task. A predicate written
    /// as `!centresTheCanvas && !previewsThePublishedBook` would put the board
    /// in Author's centre and read perfectly while doing it.
    func test_theBoardIsNotWhateverIsLeftOverFromTheOtherTwoCentreFacts() {
        XCTAssertFalse(Persona.author.centresTheCanvas,
                       "premise: Author's centre is not the canvas")
        XCTAssertFalse(Persona.author.previewsThePublishedBook,
                       "premise: nor the compiled book")
        XCTAssertFalse(Persona.author.showsTheReviewBoard,
                       "…and it is still not the board — Author's project row "
                       + "is the corkboard, which is what a complement-of-the-"
                       + "others predicate would have taken away")
    }

    /// **And it is not `editsResearchInTheCentre`'s complement either**, though
    /// today the two agree on all four personas — which is exactly why the
    /// coincidence needs a test rather than a reader's good judgement.
    ///
    /// They are different questions about the same persona: one is *"Review
    /// adjudicates, it doesn't edit research"* (Denver, stage 3b) and the other
    /// is *"Review's centre column is the board"* (M3). Derive one from the
    /// other and Review's board disappears the day a reviewer is allowed to fix
    /// a typo in a note. The behavioural half cannot see the difference while
    /// they agree, so the census is the source: the declaration must not read
    /// any of its siblings.
    func test_thePredicateIsDeclaredWithoutReadingItsSiblings() throws {
        let source = try Self.source(of: "Models/Persona.swift")
        let declaration = try XCTUnwrap(
            Self.declaration(named: "var showsTheReviewBoard: Bool {", in: source),
            "the predicate must still be a member of its own")

        for sibling in ["centresTheCanvas", "previewsThePublishedBook",
                        "editsResearchInTheCentre", "showsManuscriptDocuments"] {
            XCTAssertFalse(
                declaration.contains(sibling),
                "`showsTheReviewBoard` reads `\(sibling)`, so it is a partition "
                + "of another question rather than a fact of its own — and the "
                + "day the two questions diverge, one of them changes silently")
        }
        XCTAssertTrue(declaration.contains("case .review: return true"),
                      "premise: the scan really is reading the predicate")
        XCTAssertFalse(declaration.contains("default:"),
                       "exhaustive with no `default:`, so a fifth persona has "
                       + "to say whether its centre is the board")
    }

    // MARK: - The rule

    /// **The whole truth table, in one loop.**
    ///
    /// | subject | Review | every other persona |
    /// |---|---|---|
    /// | project / group / none / dangling / research | the BOARD | unchanged |
    /// | a document | the EDITOR — nothing over it | unchanged |
    func test_theBoardIsProjectLevelInReviewAndNowhereElse() {
        for persona in Persona.allCases {
            for (subject, shape) in ProjectAltitudeCentreTests.notADocument {
                XCTAssertEqual(
                    ProjectWindow.reviewCentreShowsBoard(
                        persona: persona, subject: subject,
                        structure: ProjectAltitudeCentreTests.structure),
                    persona.showsTheReviewBoard,
                    "\(persona) with \(shape): the layer is gated on the ONE "
                    + "spelling of \"this persona's centre is the board\"")
            }
            XCTAssertFalse(
                ProjectWindow.reviewCentreShowsBoard(
                    persona: persona, subject: .item("chapter-1"),
                    structure: ProjectAltitudeCentreTests.structure),
                "\(persona) with a chapter: a board of chips over the chapter a "
                + "reviewer is reading is the same defect the book's ruling "
                + "walked back in Publish")
        }
    }

    /// **A research subject never reaches the board, and the rule deliberately
    /// does not re-guard it.**
    ///
    /// The rule answers TRUE for `.research` — it composes `subjectShowsAltitude`,
    /// which answers the one question it is about ("does this subject name a
    /// manuscript document?") and no other. What keeps the note on screen is the
    /// ARM above: `editorPane` asks `researchSubjectPlacement` first, and in
    /// Review the item TAKES the centre (read-only, `editsResearchInTheCentre`).
    ///
    /// Both halves are pinned here rather than one, for the reason
    /// `subjectShowsAltitude`'s own comment gives: a guard written into the rule
    /// would be a second place the research routing is decided, and the one that
    /// never runs is the one that goes quietly wrong. This is a recorded
    /// dependency on the arm ORDER, so a task that reorders `editorPane` finds
    /// out here instead of on a reviewer's screen.
    func test_aResearchSubjectIsTakenByTheArmAboveAndNeverReachesTheBoard() {
        XCTAssertNotNil(
            ProjectWindow.researchSubjectPlacement(
                persona: .review, subject: .research("r1")).centreItemID,
            "Review hands the centre column to the research item, so the "
            + "manuscript arm — and the board with it — is never reached")
        XCTAssertTrue(
            ProjectWindow.reviewCentreShowsBoard(
                persona: .review, subject: .research("r1"),
                structure: ProjectAltitudeCentreTests.structure),
            "…and the rule underneath still answers TRUE, unguarded: it is the "
            + "arm above that protects the note, exactly as it protects the "
            + "corkboard from the same subject")
    }

    /// The mounted half of the pair above: in Review a research row really does
    /// put the note in the centre column, with no board over it.
    func test_aResearchSubjectInReviewShowsTheNoteAndNotTheBoard() async throws {
        let store = try await novel()
        let note = try await store.addResearchTextNote(parentId: nil, title: "Ships")
        let mount = try await host(store: store, subject: .research(note.id))

        await waitOut(0.5)
        XCTAssertNil(boardScroller(in: mount.window),
                     "the research arm above the editor arm took the centre, so "
                     + "no board is drawn. Views: \(viewNames(in: mount.window))")
        XCTAssertNil(altitudeTable(in: mount.window),
                     "…and no corkboard either, for the same reason")
    }

    /// **The rule asks the document question that already exists.**
    ///
    /// The risk that arrives with a subject-dependent layer is a second
    /// document-resolution rule beside `subjectShowsAltitude` — two answers free
    /// to disagree about what a document is, with a board of chips over the
    /// chapter a reviewer is reading as the visible cost. The census is the
    /// source; the loop under it is the behavioural half, so this is a bridge to
    /// a property rather than the property itself.
    func test_theRuleComposesTheWindowsOwnDocumentQuestion() throws {
        let source = try Self.source(of: "Views/ProjectWindow.swift")
        let rule = try XCTUnwrap(
            Self.declaration(named: "static func reviewCentreShowsBoard(", in: source))

        XCTAssertTrue(rule.contains("subjectShowsAltitude("),
                      "the project-level question is asked of the function that "
                      + "already answers it")
        XCTAssertTrue(rule.contains("showsTheReviewBoard"),
                      "…and the persona question of the predicate that names it")
        XCTAssertFalse(rule.contains("selectionIsDocument("),
                       "…and not re-derived from the primitive underneath it, "
                       + "which is how the two would come to disagree")
        XCTAssertFalse(rule.contains("TreeWalk."),
                       "…nor by walking the structure a second time")

        for (subject, shape) in ProjectAltitudeCentreTests.notADocument {
            XCTAssertEqual(
                ProjectWindow.reviewCentreShowsBoard(
                    persona: .review, subject: subject,
                    structure: ProjectAltitudeCentreTests.structure),
                ProjectWindow.subjectShowsAltitude(
                    persona: .review, subject: subject,
                    structure: ProjectAltitudeCentreTests.structure),
                "\(shape): the two must answer together in Review")
        }
    }

    /// **The persona is asked, never named** — `centresTheCanvas`'s own history
    /// is the warrant: an equality reads identically at three sites and drifts
    /// at the fourth, and that cost three separate visible defects before the
    /// question was named.
    ///
    /// `Persona.swift` is deliberately outside the scan: its `case .review:` is
    /// the predicate's own definition, which is the one place the persona is
    /// allowed to be spelled out.
    func test_theBoardsFilesAskThePredicateRatherThanNamingThePersona() throws {
        for file in ["Views/ProjectWindow.swift", "Views/Review/ReviewBoardPane.swift"] {
            let source = try Self.source(of: file)
            XCTAssertTrue(
                Self.reviewNameGates(in: source).isEmpty,
                "\(file) compares the persona by name: "
                + "\(Self.reviewNameGates(in: source)). The one spelling is "
                + "`Persona.showsTheReviewBoard`")
        }
        // The control: the scanner sees the offender it is asserting the absence
        // of, or the line above is green over any file at all.
        XCTAssertFalse(
            Self.reviewNameGates(in: "guard persona == .review else { return false }").isEmpty,
            "the scanner cannot see a planted name-gate, so its silence above "
            + "says nothing")

        XCTAssertTrue(
            try Self.source(of: "Views/ProjectWindow.swift")
                .contains("showsTheReviewBoard"),
            "the window decides something about Review's centre and must ASK "
            + "the predicate — a file that neither names the persona nor asks "
            + "the question has stopped deciding")
    }

    /// **Comments stripped, and the case name read WHOLE.**
    ///
    /// Two ways the naive spelling (`line.contains("== .review")` over raw
    /// lines) reads as an offender when nothing is wrong, both of them live in
    /// `ProjectWindow.swift` today: `c.role == .reviewer` is a collaborator's
    /// role and has nothing to do with the persona, and the rule's own doc
    /// comment quotes the forbidden shape while explaining why it is forbidden.
    /// A census that fires on its own explanation gets silenced, which is worse
    /// than not having it.
    private static func reviewNameGates(in source: String) -> [String] {
        SourceScan.codeLines(of: source)
            .filter { line in
                ["== .review", "!= .review"].contains { marker in
                    var from = line.startIndex
                    while let found = line.range(of: marker, range: from..<line.endIndex) {
                        let after = found.upperBound
                        if after == line.endIndex
                            || !(line[after].isLetter || line[after].isNumber
                                 || line[after] == "_") {
                            return true
                        }
                        from = after
                    }
                    return false
                }
            }
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: - The status footer

    /// **Why the footer needs no Review clause of its own.**
    ///
    /// The board is a new surface over the centre column and the obvious next
    /// move is a fifth clause in `showsStatusFooter` — a word count under a
    /// board of chips is a claim about a document that is not on screen. It
    /// would be a parameter that cannot change an answer: wherever
    /// `reviewCentreShowsBoard` is true, `subjectShowsAltitude` is already true,
    /// so the altitude clause has already refused. Asserted over the whole
    /// product rather than argued, which is how the same question was settled
    /// for the find overlay and for the book.
    func test_theBoardOnlyEverCoversAltitudeSoTheFooterNeedsNoClauseOfItsOwn() {
        var covered = 0
        let subjects: [BinderSubject?] = [
            nil, .project, .item("chapter-1"), .item("part-one"),
            .item("no-such-id"), .item("pathless"), .research("r1")
        ]
        for persona in Persona.allCases {
            for subject in subjects {
                for wall in [false, true] {
                    guard ProjectWindow.reviewCentreShowsBoard(
                        persona: persona, subject: subject,
                        structure: ProjectAltitudeCentreTests.structure)
                    else { continue }
                    covered += 1
                    XCTAssertTrue(
                        ProjectWindow.subjectShowsAltitude(
                            persona: persona, subject: subject,
                            structure: ProjectAltitudeCentreTests.structure),
                        "\(persona)/\(String(describing: subject)): the board "
                        + "covered something altitude does NOT cover, so the "
                        + "footer needs a clause of its own after all")
                    XCTAssertFalse(
                        ProjectWindow.showsStatusFooter(
                            persona: persona, subject: subject,
                            showsPaletteWall: wall,
                            structure: ProjectAltitudeCentreTests.structure),
                        "…and the footer must be silent under it")
                }
            }
        }
        XCTAssertGreaterThan(covered, 0,
                             "the loop never reached a covered case, so the "
                             + "implication above is vacuously true and says "
                             + "nothing")
    }

    // MARK: - Mounted: the board takes the centre

    /// **The project's own subject in Review draws the board, over the
    /// corkboard.** Altitude is still mounted underneath — that is the layered
    /// shape working, not a bug — so what says which one the reviewer sees is
    /// z-order, measured the way the OS measures it.
    func test_theProjectSubjectInReviewShowsTheBoardOverTheCorkboard() async throws {
        let store = try await novel()
        let mount = try await host(store: store, subject: .project)

        await pumpUntil(deadline: 5) { self.boardScroller(in: mount.window) != nil }
        let board = try XCTUnwrap(
            boardScroller(in: mount.window),
            "Review's centre column mounted no board. Views: "
            + "\(viewNames(in: mount.window))")
        XCTAssertNotNil(altitudeTable(in: mount.window),
                        "premise: the project subject really does put altitude "
                        + "in the stack, so this is a test about which layer is "
                        + "in FRONT rather than about which one exists")
        XCTAssertTrue(textViews(in: mount.window).isEmpty,
                      "and no editor is open under either of them")

        let hit = try middleOfTheColumn(in: mount.window)
        XCTAssertTrue(hit === board || hit.isDescendant(of: board),
                      "the middle of the column hit-tests to \(type(of: hit)) — "
                      + "the corkboard is drawn OVER the board, which is the "
                      + "truth table upside down")
    }

    /// **A group and nothing-at-all are project level too** — the two remaining
    /// subject shapes a reviewer reaches by clicking, driven through the mount
    /// rather than left to the pure rule.
    func test_aGroupAndNoSubjectAtAllInReviewAlsoShowTheBoard() async throws {
        let store = try await novel()
        let group = try await store.addStructureItem(
            parentId: nil, title: "Part One", kind: .group)

        for (subject, shape) in [(BinderSubject?.some(.item(group.id)), "a group"),
                                 (nil, "no subject at all")] {
            let mount = try await host(store: store, subject: subject)
            await pumpUntil(deadline: 5) { self.boardScroller(in: mount.window) != nil }
            XCTAssertNotNil(boardScroller(in: mount.window),
                            "\(shape) names no document, so Review's centre is "
                            + "the board. Views: \(viewNames(in: mount.window))")
            XCTAssertTrue(textViews(in: mount.window).isEmpty,
                          "\(shape): and no editor is open behind it")
        }
    }

    /// **A chapter subject in Review opens the chapter, exactly as today.** The
    /// row this task deliberately did not change — a reviewer with a note to
    /// leave needs the prose, and a board over it is the defect Denver's
    /// 2026-08-12 ruling walked back in Publish.
    func test_aDocumentSubjectInReviewOpensTheEditorAndNothingCoversIt() async throws {
        let store = try await novel()
        let chapter = try Self.firstDocument(in: store)
        let mount = try await host(store: store, subject: .item(chapter.id))

        await pumpUntil(deadline: 5) { !self.textViews(in: mount.window).isEmpty }
        XCTAssertFalse(textViews(in: mount.window).isEmpty,
                       "the chapter must open. Views: \(viewNames(in: mount.window))")
        XCTAssertNil(boardScroller(in: mount.window),
                     "…and the board must not be drawn over it")
        XCTAssertNil(altitudeTable(in: mount.window),
                     "…nor the corkboard")
    }

    /// **The control that makes the readings above discriminate.** Author's
    /// project row is the corkboard and stays the corkboard, so the same window
    /// with the same subject must mount no board at all — otherwise
    /// `boardScroller` is finding something every persona has and every
    /// assertion above is green over any routing at all.
    func test_control_authorsProjectRowIsStillTheCorkboardAndMountsNoBoard() async throws {
        let store = try await novel()
        let mount = try await host(store: store, persona: .author, subject: .project)

        await pumpUntil(deadline: 5) { self.altitudeTable(in: mount.window) != nil }
        XCTAssertNotNil(altitudeTable(in: mount.window),
                        "premise: Author's project row draws altitude")
        XCTAssertNil(boardScroller(in: mount.window),
                     "Author mounted a board — either the gate is not asking "
                     + "the persona, or `boardScroller` is reading a view every "
                     + "centre column has. Views: \(viewNames(in: mount.window))")
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
        let mount = try await host(store: store, subject: .project)

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
        mount.box.subject = .item(chapter.id)
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

        mount.box.subject = .project
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

    /// **The PERSONA hop — Review's board up, ⌘4 to Publish, ⌘3 back — tears
    /// the host down ZERO times** (the whole-branch review's seam 3: the board
    /// layer × the publish layer in one ZStack, a trip no per-task test made
    /// because each probe models its own persona's layer only).
    ///
    /// What this drives that the subject round trip above cannot: the persona
    /// is the OTHER input to `reviewCentreShowsBoard`, and a persona write
    /// re-runs every routing decision in the centre — `editorRoute`,
    /// `researchSubjectPlacement`, both layer gates — in one render. The host
    /// must ride through all of it, because ⌘3/⌘4 is a keystroke the writer
    /// makes constantly and `.onDisappear` here is `doc.close()` +
    /// `unregister(path:)`.
    ///
    /// The probe deliberately does not mount Publish's BOOK layer (its own
    /// suite owns that probe — see the probe's doc), so what stands over
    /// altitude in Publish here is nothing rather than the book; the layer
    /// gates and the host's lifetime are production's own statics either way.
    func test_aPersonaHopToPublishAndBackNeverTearsTheHostDown() async throws {
        let store = try await novel()
        let mount = try await host(store: store, subject: .project)

        await pumpUntil(deadline: 5) {
            self.boardScroller(in: mount.window) != nil
                && mount.hostLife.appearances == 1
        }
        XCTAssertNotNil(boardScroller(in: mount.window),
                        "premise: Review at project level shows the board")
        XCTAssertEqual(mount.hostLife.appearances, 1, "premise: the host mounted")
        XCTAssertEqual(mount.hostLife.disappearances, 0, "premise: and is still up")

        // ⌘4 — the persona moves; the subject stays at .project.
        mount.box.persona = .publish
        await pumpUntil(deadline: 5) { self.boardScroller(in: mount.window) == nil }
        XCTAssertNil(boardScroller(in: mount.window),
                     "the board is Review's alone — Publish at project level "
                     + "must not keep it mounted")
        XCTAssertNotNil(altitudeTable(in: mount.window),
                        "premise: Publish at project level still shows altitude "
                        + "underneath (the probe mounts no book layer)")
        XCTAssertEqual(mount.hostLife.disappearances, 0,
                       "the host was torn down on ⌘4 — a persona hop must only "
                       + "swap the layers over it, never the host")

        // ⌘3 — back to Review; the board returns over the same host.
        mount.box.persona = .review
        await pumpUntil(deadline: 5) { self.boardScroller(in: mount.window) != nil }
        XCTAssertNotNil(boardScroller(in: mount.window), "the board is back")
        XCTAssertEqual(mount.hostLife.disappearances, 0,
                       "the host was torn down on the way back — same ZStack, "
                       + "same host, or ⌘3⌘4 costs a document close per keystroke")
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
        let mount = try await host(store: store, subject: .item(chapter.id),
                                   shape: .ownArm)

        await pumpUntil(deadline: 5) { mount.hostLife.appearances == 1 }
        XCTAssertEqual(mount.hostLife.appearances, 1,
                       "premise: the arm shape mounts the host on the chapter")

        mount.box.subject = .project
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
        let mount = try await host(store: store, subject: .project)

        await pumpUntil(deadline: 5) {
            self.boardScroller(in: mount.window) != nil
                && self.orderedChips(in: mount.window).count >= documents.count * passes.count
        }
        let chips = orderedChips(in: mount.window)
        XCTAssertEqual(chips.count, documents.count * passes.count,
                       "premise: one chip per (piece × pass)")
        XCTAssertEqual(mount.hostLife.disappearances, 0, "premise: nothing torn down yet")

        await click(chips[passes.count + 1], in: mount.window, until: {
            mount.box.subject == .item(second.id)
                && !self.textViews(in: mount.window).isEmpty
        })

        XCTAssertEqual(mount.box.subject, .item(second.id),
                       "the click must take the window's subject to the piece "
                       + "the chip is drawn for")
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
        XCTAssertEqual(mount.box.persona, .review,
                       "and the board moved no persona: it is a surface Review "
                       + "shows, not a thing that decides Review is showing")
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
        let mount = try await host(store: store, subject: .project)
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

        let verbs = ReviewBoardChipVerbs(onSetState: { piece, passId, state in
            Task { try? await store.setPassState(id: piece, passId: passId, state) }
        })
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
    /// own statics, but the SHAPE of the last arm is the probe's own and a probe
    /// cannot vouch for it. This reads the real `manuscriptEditor`.
    func test_theBoardIsALayerOfTheSameZStackAndNotAnArmOfItsOwn() throws {
        let source = try Self.source(of: "Views/ProjectWindow.swift")
        let arm = try XCTUnwrap(
            Self.declaration(named: "private func manuscriptEditor(", in: source),
            "the editor arm must still be a member of its own")

        XCTAssertTrue(arm.contains("ZStack"), "still one stack, not a choice")
        XCTAssertTrue(arm.contains("EditorHost("),
                      "…with the host mounted unconditionally underneath")
        XCTAssertTrue(arm.contains("ProjectAltitudePane("), "…altitude over it")
        XCTAssertTrue(arm.contains("ReviewBoardPane("),
                      "…and Review's board over that")
        XCTAssertTrue(arm.contains("Self.reviewCentreShowsBoard("),
                      "gated on the ONE named rule rather than on a second "
                      + "spelling written out here — and a second gate is how a "
                      + "board ends up over the chapter a reviewer is reading")

        let altitudeAt = try XCTUnwrap(arm.range(of: "ProjectAltitudePane("))
        let boardAt = try XCTUnwrap(arm.range(of: "ReviewBoardPane("))
        let bookAt = try XCTUnwrap(arm.range(of: "PublishPreviewCentre("))
        XCTAssertTrue(altitudeAt.lowerBound < boardAt.lowerBound,
                      "the board must be OVER altitude — a corkboard drawn over "
                      + "the board is the truth table read upside down")
        XCTAssertTrue(boardAt.lowerBound < bookAt.lowerBound,
                      "…and the book must stay the LAST layer of the stack, "
                      + "which is what `PublishPreviewCentreTests` pins")

        XCTAssertEqual(
            Self.occurrences(of: "ReviewBoardPane(", in: source), 1,
            "one mount for the board, in the centre column's overlay. A second "
            + "is a surface nobody decided to add")
        XCTAssertEqual(
            Self.occurrences(of: "manuscriptEditor(", in: source), 2,
            "the declaration and exactly ONE call — `editorPane`'s last arm, "
            + "unchanged by this task")
    }

    /// The control for the scan above: `declaration(named:)` must BOUND the text
    /// it reads to the one member, or every assertion in it is really about the
    /// whole file and cannot fail. `CanvasView(` is mounted in this same file,
    /// one member down, and must not be visible from inside the editor arm.
    func test_theArmScanReadsTheArmAndNotTheWholeFile() throws {
        let source = try Self.source(of: "Views/ProjectWindow.swift")
        let arm = try XCTUnwrap(
            Self.declaration(named: "private func manuscriptEditor(", in: source))
        XCTAssertTrue(source.contains("CanvasView("),
                      "premise: the file really does mount the canvas")
        XCTAssertFalse(arm.contains("CanvasView("),
                       "…and the scan above cannot see it, so what it asserts "
                       + "is about the editor arm rather than about the file")
    }

    /// **The ejection trap: nothing this task added moves the window's
    /// persona.** The board is a surface Review shows, never a thing that
    /// decides Review is showing — a layer that wrote the persona would fight
    /// the picker, ⌘1–4 and `ManuscriptNavigation` for it.
    /// `TripwireGrepTests.test_theWindowsPersonaIsWrittenOnlyFromTheClosedSetOfDecisionSites`
    /// is the census over the whole tree; this is the same claim about the one
    /// new file, stated where the new file's own suite can see it.
    func test_theBoardsOwnFileWritesNoPersona() throws {
        let source = try Self.source(of: "Views/Review/ReviewBoardPane.swift")
        for shape in ["persona = ", "persona.wrappedValue = ", "$0.persona = "] {
            XCTAssertFalse(source.contains(shape),
                           "`ReviewBoardPane` writes the window's persona "
                           + "(`\(shape)`) — the closed set of decision sites is "
                           + "`ManuscriptNavigation`, `PersonaModifier`, "
                           + "`CanvasClaudeArrivalModifier` and `TreeTravel`")
        }
    }

    /// **What the production mount's chips are wired TO** (M3 P1 Task 8).
    ///
    /// The mounted tests above drive the probe, and the probe's closures are the
    /// probe's own — so this reads the real call's argument list, bounded to it,
    /// and checks the three facts that make a chip click the hop it is: the
    /// window's SUBJECT moves, the pass is recorded, and the ruling goes through
    /// the store. Plus the ejection trap's other half: no persona write rides
    /// along. `test_theBoardsOwnFileWritesNoPersona` covers the pane's file;
    /// this covers the closures the pane is handed, which live here.
    func test_theBoardsChipsAreWiredToTheWindowsSubjectAndTheStore() throws {
        let source = try Self.source(of: "Views/ProjectWindow.swift")
        let arm = try XCTUnwrap(
            Self.declaration(named: "private func manuscriptEditor(", in: source))
        let call = try XCTUnwrap(Self.argumentList(after: "ReviewBoardPane(", in: arm),
                                 "the board's mount must still be a call with "
                                 + "arguments this scan can read")
        // Comment lines dropped before the forbidden-pattern half: the mount's
        // own comment explains at length why the persona is NOT written there,
        // and a scan that could not tell the explanation from the act would be
        // a census that fires on its own documentation.
        let code = SourceScan.codeLines(of: call).joined(separator: "\n")

        for expected in ["onNavigate:", "selectedSubject = .item(",
                         "recordActivePass(forPiece:", "onSetState:",
                         "store.setPassState("] {
            XCTAssertTrue(code.contains(expected),
                          "the board's mount does not pass `\(expected)`")
        }
        XCTAssertFalse(
            code.contains("persona"),
            "the board's own closures move the window's PERSONA. The board is a "
            + "surface Review shows, never a thing that decides Review is "
            + "showing — a layer that wrote the persona would fight the picker, "
            + "⌘1–4 and `ManuscriptNavigation` for it "
            + "(`TripwireGrepTests.test_theWindowsPersonaIsWrittenOnlyFromThe"
            + "ClosedSetOfDecisionSites`)")
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
    /// the scope) and neither the subject nor the persona.
    func test_theCountIsWiredToTheQueueAndMovesNeitherSubjectNorPersona() throws {
        let source = try Self.source(of: "Views/ProjectWindow.swift")
        let arm = try XCTUnwrap(
            Self.declaration(named: "private func manuscriptEditor(", in: source))
        let call = try XCTUnwrap(Self.argumentList(after: "ReviewBoardPane(", in: arm))
        let code = SourceScan.codeLines(of: call).joined(separator: "\n")
        let closure = try XCTUnwrap(
            Self.closureBody(after: "onOpenNotes: { pieceId in", in: code),
            "the mount must still wire `onOpenNotes` as a closure this scan "
            + "can read")

        for expected in ["showInspector = true",
                         "detailSegment = .annotations",
                         "annotationScopeRequest = .project(focusPiece: pieceId)"] {
            XCTAssertTrue(closure.contains(expected),
                          "the count's closure does not `\(expected)` — the "
                          + "click has to land the writer IN the queue, in "
                          + "project scope, at the piece they pressed")
        }
        // The control for the two refusals below: the mount's OTHER closure
        // does write the subject, one argument away, so a scan that ran past
        // its own braces would find it and this test could not fail.
        XCTAssertTrue(code.contains("selectedSubject = .item("),
                      "premise: the chip's closure, in the same call, travels")
        XCTAssertFalse(
            closure.contains("selectedSubject"),
            "the count click writes the window's SUBJECT, so pressing a number "
            + "on the board throws the board away — that is the chip's verb, "
            + "not this one")
        XCTAssertFalse(
            closure.contains("persona"),
            "…and it must not write the persona either (the ejection trap, "
            + "`TripwireGrepTests.test_theWindowsPersonaIsWrittenOnlyFromThe"
            + "ClosedSetOfDecisionSites`)")

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
        let source = try Self.source(of: "Views/ProjectWindow.swift")
        let arm = try XCTUnwrap(
            Self.declaration(named: "private func manuscriptEditor(", in: source))

        XCTAssertTrue(arm.contains(".task { refreshOpenNotes(store: store) }"),
                      "the board must recount when it appears")
        XCTAssertTrue(arm.contains(".onProjectEvent(.maughamAnnotationsChanged"),
                      "…and when the project says its notes changed — through "
                      + "the receive helper that owns the scope filter and the "
                      + "closed-window liveness guard (ADR 0021)")

        let refresh = try XCTUnwrap(
            Self.declaration(named: "private func refreshOpenNotes(", in: source),
            "`refreshOpenNotes` is gone or renamed — this census is stale")
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
    /// call's own closing paren. `ProjectAltitudePane(` is mounted in the same
    /// arm, one layer up, and its arguments must not be visible from inside the
    /// board's — or the scan is really reading the arm again and cannot fail.
    func test_theBoardsArgumentScanStopsAtItsOwnCall() throws {
        let source = try Self.source(of: "Views/ProjectWindow.swift")
        let arm = try XCTUnwrap(
            Self.declaration(named: "private func manuscriptEditor(", in: source))
        let call = try XCTUnwrap(Self.argumentList(after: "ReviewBoardPane(", in: arm))

        XCTAssertTrue(arm.contains("ProjectAltitudePane("),
                      "premise: the arm really does mount altitude too")
        XCTAssertFalse(call.contains("ProjectAltitudePane("),
                       "the board's argument scan ran past its own call")
        XCTAssertFalse(call.contains("EditorHost("),
                       "…and past the host underneath it")

        // The other half of the scan above: its persona check runs over CODE
        // lines only, and this is what says that filter is doing work rather
        // than passing because nothing in the call mentions a persona at all.
        XCTAssertTrue(call.contains("persona"),
                      "premise: the mount's own comment explains why the click "
                      + "moves no persona — so a scan that did not drop comments "
                      + "would fire on that explanation")
        XCTAssertFalse(SourceScan.codeLines(of: call).joined(separator: "\n")
                        .contains("persona"),
                       "…and with comments dropped, nothing is left")
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
                      persona: Persona = .review,
                      subject: BinderSubject? = nil,
                      shape: ReviewCentreProbeView.Shape = .layered)
    async throws -> Mount {
        let documentStore = try await DocumentStore.open(url: store.url)
        store.documentStore = documentStore
        documentStores.append(documentStore)

        let box = ReviewCentreProbeBox(persona: persona, subject: subject)
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

        let frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        let hosting = NSHostingView(rootView: AnyView(root))
        hosting.frame = frame
        let window = SilentTestWindow(contentRect: frame, styleMask: [.titled],
                                      backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
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
    /// `test_control_authorsProjectRowIsStillTheCorkboardAndMountsNoBoard` is
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
            parentId: nil, title: "Chapter Two", kind: .document(extension: "md"))
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
/// move the persona and the subject the way the window does.
@Observable
@MainActor
final class ReviewCentreProbeBox {
    var persona: Persona
    var subject: BinderSubject?
    /// Pieces whose open-notes count was clicked (M3 P2 Task 9).
    var openedNotesFor: [String] = []

    init(persona: Persona, subject: BinderSubject?) {
        self.persona = persona
        self.subject = subject
    }
}

/// **The centre column, wired the way `editorPane` wires it** — the research
/// placement, the canvas route, the Collection reference arm, then the editor
/// arm — with every decision taken from production's own statics rather than
/// re-spelled here. A probe that decided for itself which arm applies would be
/// testing the probe.
///
/// What it spells for itself is the SHAPE of the last arm, which is the thing
/// under test and cannot be reached from outside `ProjectWindow`
/// (`manuscriptEditor` is private, and it reads the window's `@State`). Hence
/// two cases: `.layered` is what production does, and `.ownArm` is the shape
/// this task rejected, driven by the control test so the lifetime counter is
/// proven able to see a teardown.
///
/// The publish layer is deliberately not modelled: nothing here is Publish, and
/// `PublishPreviewCentreTests` owns that layer's own probe.
@MainActor
struct ReviewCentreProbeView: View {
    enum Shape { case layered, ownArm }

    let store: ProjectStore
    let documentStore: DocumentStore
    let box: ReviewCentreProbeBox
    let hostLife: EditorHostLifeCounter
    let shape: Shape
    let canvasModel: CanvasModel

    @State private var layout: OutlineLayout = .table
    @State private var control = EditorControl()

    private var subject: Binding<BinderSubject?> {
        Binding(get: { box.subject }, set: { box.subject = $0 })
    }

    private var referencePiece: StructureItem? {
        guard let id = box.subject?.itemID,
              let piece = store.manifest.structure.first(where: { $0.id == id }),
              piece.pieceKind == .reference
        else { return nil }
        return piece
    }

    var body: some View {
        centre.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var centre: some View {
        let route = ProjectWindow.editorRoute(
            persona: box.persona, projectType: store.manifest.type,
            selectedPieceIsReference: referencePiece != nil)
        if let id = ProjectWindow.researchSubjectPlacement(
            persona: box.persona, subject: box.subject).centreItemID {
            ResearchSubjectCentre(store: store, documentStore: documentStore,
                                  itemID: id, previewVisible: false,
                                  readOnly: !box.persona.editsResearchInTheCentre)
        } else if route == .canvas {
            CanvasView(model: canvasModel, projectRoot: store.url,
                       paletteSwatchHexes: { [] })
        } else if route == .collectionReference, let piece = referencePiece {
            ReferencePlaceholderCard(piece: piece, onOpen: {})
        } else {
            manuscriptCentre
        }
    }

    @ViewBuilder
    private var manuscriptCentre: some View {
        switch shape {
        case .layered:
            ZStack {
                editor
                if showsAltitude { altitude }
                if showsBoard { board }
            }
        case .ownArm:
            if showsBoard {
                board
            } else if showsAltitude {
                altitude
            } else {
                editor
            }
        }
    }

    private var showsAltitude: Bool {
        ProjectWindow.subjectShowsAltitude(persona: box.persona,
                                           subject: box.subject,
                                           structure: store.manifest.structure)
    }

    private var showsBoard: Bool {
        ProjectWindow.reviewCentreShowsBoard(persona: box.persona,
                                             subject: box.subject,
                                             structure: store.manifest.structure)
    }

    private var editor: some View {
        EditorHost(store: store, documentStore: documentStore,
                   selectedItemId: box.subject?.itemID, control: control)
            .onAppear { hostLife.appeared() }
            .onDisappear { hostLife.disappeared() }
    }

    private var altitude: some View {
        ProjectAltitudePane(store: store, layout: $layout,
                            selectedSubject: subject, title: store.manifest.title)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
    }

    /// **Wired the way the production mount is wired** (Task 8): a chip click
    /// writes the SUBJECT and records the pass, and a menu verb writes through
    /// the store. The probe cannot vouch for production's own closures — those
    /// are read off `manuscriptEditor`'s text by
    /// `test_theBoardsChipsAreWiredToTheWindowsSubjectAndTheStore` — but it can
    /// carry what a click DOES through a real mounted board, which is what the
    /// hop tests here drive.
    ///
    /// Production also updates its `@State` copy of `ActivePassMemory`; the
    /// probe has no window state of its own, so the persisted half is what it
    /// models and what the tests read back.
    private var board: some View {
        ReviewBoardPane(
            title: store.manifest.title,
            structure: store.manifest.structure,
            passes: store.manifest.effectiveReviewPasses,
            // The counts are the WINDOW's own state in production, refreshed
            // off the body path; the probe has no window state, so it models
            // the shape that matters here — values in, and a click that does
            // not move the centre.
            openNotes: [:],
            unreadableDocIds: [],
            onOpenNotes: { box.openedNotesFor.append($0) },
            onNavigate: { pieceId, passId in
                box.subject = .item(pieceId)
                documentStore.updateUIState {
                    $0.activePassMemory.record(piece: pieceId, passId: passId)
                }
            },
            onSetState: { pieceId, passId, state in
                Task { try? await store.setPassState(id: pieceId, passId: passId, state) }
            })
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}
