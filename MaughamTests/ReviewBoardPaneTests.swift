import XCTest
import AppKit
import ApplicationServices
import SwiftUI
import MaughamCore
@testable import Maugham

/// **What the Review board DRAWS, and what its chips DO** (M3 P1 Tasks 7 & 8).
/// `ReviewBoardRoutingTests` (Task 6) is about the pane's place in the centre
/// column's stack; this file is about its contents: the chip per (piece × pass),
/// the states those chips show, the group headers, the chip-less reference row,
/// the empty project, the two scrolling axes that are the pane's and never the
/// window's — and, as of Task 8, the two things a chip does: a click that names
/// its own cell, and a menu whose four verbs rule on it.
///
/// **Nothing here needs a project on disk**, which is itself the point. The pane
/// takes a title, a structure array and a pass list — no `ProjectStore`, no
/// `DocumentStore`, no `Document` — so the whole surface is drivable from
/// literal `StructureItem`s. That is tripwire 4 satisfied by construction rather
/// than by inspection, and `test_theSourceReadsNoStoreAtAll` is the census that
/// keeps it that way.
///
/// **How a chip is observed.** SwiftUI on this SDK backs a `Button` with no
/// `NSButton` (measured and recorded in `ProjectAltitudePaneTests` and
/// `InspectorIntentAffordanceTests`) — but each button does mount its own
/// focus-ring container as a real `NSView`, one per `ForEach` element, at the
/// frame the layout gave it. Counting those containers is the reliable
/// structural reading of "how many chips are on this board", and it holds
/// precisely because the rows carry no OTHER buttons.
///
/// **Task 8 re-derived that premise rather than inheriting it** (Task 7's own
/// carry). Wiring the chips added no second control: a click is the chip's own
/// `Button` action, and the menu is a `.contextMenu` on that same button, which
/// mounts nothing until a right-click builds it. Titles, group headers and
/// reference rows are still plain `Text`. So `chips(in:)` is still exact, and
/// the exact counts in this file are what would go red the day a row grows a
/// clickable title — at which point the helper must be re-derived (an
/// accessibility identifier on the chip is the obvious replacement), not the
/// counts loosened.
///
/// **M3 P2 Task 9 added the board's second control and re-derived it again.**
/// The open-notes column draws a `Button` for a piece that HAS open notes, and
/// nothing at all — no view, no control — for one that does not; an unreadable
/// piece draws a plain `Text` dash. So `chips(in:)` now counts chips PLUS
/// counted cells, which is why every mounted expectation here reads
/// `pieces × passes + <counted pieces>` and why the suite's older tests, which
/// mount with no counts at all, still mean exactly what they meant. That the
/// uncounted cases add no control is not incidental — it is
/// `test_aPieceWithNothingOpenAddsNoControl` and
/// `test_anUnreadablePieceOffersNoClick`.
///
/// The accessibility tree carries the state each chip is showing, and the test
/// that reads it skips by name when no assistive client can attach.
@MainActor
final class ReviewBoardPaneTests: XCTestCase {

    private var windows: [NSWindow] = []

    /// What a mounted board told its host to do — one recorder per test, since
    /// XCTest builds a fresh instance for each.
    private let calls = BoardCalls()

    /// The verb factory under test, recording into this test's own `calls`.
    private var verbs: ReviewBoardChipVerbs {
        ReviewBoardChipVerbs(
            onSetState: { [calls] piece, pass, state in
                calls.writes.append(BoardWrite(piece: piece, pass: pass, state: state))
            },
            onRunRound: { [calls] piece, pass in
                calls.runs.append(BoardClick(piece: piece, pass: pass))
            })
    }

    override func tearDown() async throws {
        for window in windows { window.contentView = NSView(frame: .zero) }
        pump(0.05)
        windows.removeAll()
    }

    // MARK: - Fixtures

    private static let passes = ReviewPass.presets  // four: structural, line, copyedit, proof

    private func doc(_ id: String, _ title: String, states: [String: PassState]? = nil,
                     kind: PieceKind? = nil) -> StructureItem {
        StructureItem(id: id, title: title, type: .document, path: "\(id).md",
                      pieceKind: kind, passStates: states)
    }

    private func group(_ id: String, _ title: String, _ children: [StructureItem]) -> StructureItem {
        StructureItem(id: id, title: title, type: .group, children: children)
    }

    // MARK: - The chip's own truth table (no window)

    /// **The chip's colour is the projection's, cell by cell.** Each state is
    /// asserted against the status the rest of the app would paint for a piece
    /// standing exactly there: `.done` and `.skipped` are complete (an
    /// all-skipped piece is `final`, the spec's recorded edge), `.inProgress`
    /// and an `.unknown` written by a newer build are open, and untouched is
    /// draft.
    ///
    /// Concrete expectations, not a re-derivation: this is what fails if the
    /// chip ever grows a switch of its own that disagrees with
    /// `ReviewStatus.derived`.
    func test_everyChipStateMapsToTheStatusTheRestOfTheAppWouldPaint() {
        XCTAssertEqual(ReviewBoardChip.status(for: nil), .draft,
                       "untouched is draft — nothing has been ruled on")
        XCTAssertEqual(ReviewBoardChip.status(for: .inProgress), .revising)
        XCTAssertEqual(ReviewBoardChip.status(for: .done), .final)
        XCTAssertEqual(ReviewBoardChip.status(for: .skipped), .final,
                       "a skip is an adjudication, not an omission")
        XCTAssertEqual(ReviewBoardChip.status(for: .unknown("hyphenated")), .revising,
                       "a state this build cannot read is touched-but-open — "
                       + "never promoted to complete")
    }

    /// …and those statuses reach the pixel through `StatusSwatch`, the one
    /// place a `ReviewStatus` becomes a `Color`, so the board and the tree's
    /// dots cannot drift.
    func test_theChipsColoursComeFromTheOneSwatch() {
        XCTAssertEqual(StatusSwatch.color(for: ReviewBoardChip.status(for: .done)),
                       StatusSwatch.color(for: .final))
        XCTAssertNotEqual(StatusSwatch.color(for: ReviewBoardChip.status(for: .done)),
                          StatusSwatch.color(for: ReviewBoardChip.status(for: nil)),
                          "premise: done and untouched are not the same colour, "
                          + "or the assertion above is about nothing")
    }

    /// Every state gets a glyph of its own — a board where two states look
    /// alike is a board that cannot be read.
    func test_everyStateHasItsOwnGlyph() {
        let states: [PassState?] = [nil, .inProgress, .done, .skipped, .unknown("x")]
        let symbols = states.map { ReviewBoardChip.symbol(for: $0) }

        XCTAssertEqual(Set(symbols).count, states.count,
                       "two states share a glyph: \(symbols)")
        XCTAssertFalse(symbols.contains(""), "and none of them is blank")
    }

    /// **The chip says the state in the SAME words the writer set it with** —
    /// `PassLadder`'s titles, read rather than restated, so the inspector and
    /// the board cannot call the same state two different things.
    func test_theChipSpeaksTheLaddersOwnWords() {
        XCTAssertEqual(ReviewBoardChip.stateTitle(for: nil), PassLadder.untouchedTitle)
        XCTAssertEqual(ReviewBoardChip.stateTitle(for: .inProgress), PassLadder.inProgressTitle)
        XCTAssertEqual(ReviewBoardChip.stateTitle(for: .done), PassLadder.doneTitle)
        XCTAssertEqual(ReviewBoardChip.stateTitle(for: .skipped), PassLadder.skipTitle)
        XCTAssertEqual(ReviewBoardChip.stateTitle(for: .unknown("triage")), "triage",
                       "a future build's state shows the value it actually holds")
    }

    /// A chip is a glyph in a grid, so its label has to carry the whole cell:
    /// which piece, which pass, what state.
    func test_theChipsLabelNamesThePieceThePassAndTheState() {
        let label = ReviewBoardChip.label(
            piece: "Chapter One",
            pass: ReviewPass(id: "line", name: "Line"),
            state: .done)

        for fragment in ["Chapter One", "Line", PassLadder.doneTitle] {
            XCTAssertTrue(label.contains(fragment),
                          "\u{201C}\(label)\u{201D} does not name \(fragment)")
        }
    }

    // MARK: - The chip's menu (no window)

    /// **The menu is asserted at the factory, not at the menu** (M3 P1 Task 8).
    /// `.contextMenu` builds its `NSMenu` on the right-click itself and is
    /// unreachable from a headless test — `BinderView.linkResearchVerb`'s
    /// discipline — so `ReviewBoardChipVerbs` is exposed and its truth table is
    /// driven here. The alternative is a menu asserted nowhere.

    /// Four verbs, in the ladder's order, in the ladder's words. Untouched comes
    /// FIRST because clearing a pass is a ruling like any other; buried under
    /// the three positive ones it reads as an absence.
    func test_theMenuOffersTheLaddersFourStatesInItsOwnWords() {
        let items = verbs.chipMenuItems(for: "ch1", passId: "line", current: nil)

        XCTAssertEqual(items.map(\.title),
                       [PassLadder.untouchedTitle, PassLadder.inProgressTitle,
                        PassLadder.doneTitle, PassLadder.skipTitle],
                       "the board's menu and the Inspector's ladder must call "
                       + "the same state the same thing")
        XCTAssertEqual(items.map(\.state), [nil, .inProgress, .done, .skipped])
    }

    /// **Exactly one checkmark, and it is on the state the cell is in.** Driven
    /// over all four so a factory that checkmarked, say, the first row whatever
    /// the cell held cannot pass on the one case that happens to agree.
    func test_theCurrentStateIsTheOneVerbCheckmarked() {
        for current in ReviewBoardChipVerbs.offeredStates {
            let items = verbs.chipMenuItems(for: "ch1", passId: "line", current: current)
            let checked = items.filter(\.isCurrent)

            XCTAssertEqual(checked.count, 1,
                           "\(String(describing: current)): one checkmark, not "
                           + "\(checked.count)")
            XCTAssertEqual(checked.first?.state, current,
                           "…and on the state the cell actually holds")
        }
    }

    /// **A state this build cannot read checkmarks NOTHING** — and still offers
    /// all four. Checkmarking one of them would claim the piece stands somewhere
    /// it does not; offering none would leave the writer unable to correct a
    /// value they can see on the chip. (`PassLadder`'s picker keeps a fifth row
    /// for the raw value because a `Picker` selection must match a tag or the
    /// popup renders blank; a menu of verbs has no such constraint, and a verb
    /// that re-set the unknown would be a control with no effect.)
    func test_anUnknownStateChecksNothingAndStillOffersTheFour() {
        let items = verbs.chipMenuItems(for: "ch1", passId: "line",
                                        current: .unknown("hyphenated"))

        XCTAssertEqual(items.count, 4)
        XCTAssertTrue(items.allSatisfy { !$0.isCurrent },
                      "no verb may claim to be a state written by a newer build")
        XCTAssertFalse(items.contains { $0.state == .unknown("hyphenated") },
                       "…and none of them offers to set it back")
    }

    /// **Pressing a verb writes THAT cell, in THAT state.** The ids are the ones
    /// the factory was asked about — a verb built for one cell can never write
    /// another's, which on a grid is the whole safety property.
    func test_eachVerbWritesItsOwnCellAndItsOwnState() {
        let items = verbs.chipMenuItems(for: "ch2", passId: "copyedit", current: .done)
        for item in items { item.perform() }

        XCTAssertEqual(calls.writes,
                       [BoardWrite(piece: "ch2", pass: "copyedit", state: nil),
                        BoardWrite(piece: "ch2", pass: "copyedit", state: .inProgress),
                        BoardWrite(piece: "ch2", pass: "copyedit", state: .done),
                        BoardWrite(piece: "ch2", pass: "copyedit", state: .skipped)],
                       "each verb forwards its own state for its own cell — and "
                       + "untouched is `nil`, which is what makes the store verb "
                       + "REMOVE the key rather than store a fourth state")
    }

    /// The verbs write and do nothing else: no navigation rides along with a
    /// ruling. Setting a state from the board must not move the writer off the
    /// board they are ruling from.
    func test_aVerbNavigatesNowhere() {
        for item in verbs.chipMenuItems(for: "ch1", passId: "line", current: nil) {
            item.perform()
        }
        XCTAssertTrue(calls.navigations.isEmpty,
                      "a ruling is not a navigation — the reviewer stays on the "
                      + "board")
        XCTAssertTrue(calls.runs.isEmpty,
                      "…and a ruling is not a round either: `Done` must not "
                      + "spawn a check on its way past")
    }

    // MARK: - The chip's menu: the round (M4 P2 Task 4)

    /// **The board's cell can start the round it stands for.** Until this the
    /// board said where every piece stood and offered no way to move any of it:
    /// the reviewer read the grid, clicked a chip, landed in the piece, found
    /// the cockpit and pressed Run. The menu's first item is that whole path.
    ///
    /// It is named for the EDITOR, not the pass — "Run Gould's round", the same
    /// spelling the empty queue teaches (`RoundNarrative.runRoundTitle`) — so
    /// the grid and the queue name one act one way.
    func test_theMenuLeadsWithTheRoundNamedForThePassesEditor() {
        // A preset-id pass carrying no editor of its own, which is what a
        // customized manifest stores: the title must still say "Gould", which
        // it can only do through `effectiveEditorName`.
        let stored = ReviewPass(id: "copyedit", name: "Copyedit")
        let menu = verbs.chipMenu(for: "ch1", pass: stored, current: nil)

        XCTAssertEqual(menu.run.title, "Run Gould\u{2019}s round",
                       "the round is offered by the name of the editor who "
                       + "reads it \u{2014} `effectiveEditorName`, never the "
                       + "raw stored field")
        XCTAssertEqual(menu.run.title,
                       RoundNarrative.runRoundTitle(editorName: "Gould"),
                       "\u{2026}and through the ONE spelling the cockpit's "
                       + "empty state reads, so the two surfaces cannot drift")
    }

    /// A pass a writer named themselves and never gave an editor falls back to
    /// its own name (`ReviewPass.effectiveEditorName`) — so the verb reads
    /// "Run Beta Read's round" rather than naming a person who does not exist.
    func test_theRoundVerbNamesAWriterOwnPassByItsOwnName() {
        let menu = verbs.chipMenu(
            for: "ch1", pass: ReviewPass(id: "beta", name: "Beta Read"), current: nil)
        XCTAssertEqual(menu.run.title, "Run Beta Read\u{2019}s round")
    }

    /// **The round verb carries its own cell's two ids**, exactly as the four
    /// state verbs do — asked about the second piece's non-first pass so
    /// neither id could be the first of anything.
    func test_theRoundVerbCarriesItsOwnCell() {
        let menu = verbs.chipMenu(
            for: "ch2", pass: ReviewPass(id: "line", name: "Line"), current: .inProgress)
        menu.run.perform()

        XCTAssertEqual(calls.runs, [BoardClick(piece: "ch2", pass: "line")],
                       "the round runs on the cell it was drawn in")
        XCTAssertTrue(calls.writes.isEmpty,
                      "a round is not a ruling \u{2014} asking for a check must "
                      + "not also mark the pass in progress")
    }

    /// **Every cell offers its round, whatever it stands at.** A finished pass
    /// is exactly where a reviewer wants one more look, and a skipped one is a
    /// ruling the writer can revisit; a menu that withheld the verb on two of
    /// the five states would be a control that vanishes when you need it.
    func test_everyStateStillOffersItsRound() {
        for current in ReviewBoardChipVerbs.offeredStates + [.unknown("hyphenated")] {
            let menu = verbs.chipMenu(
                for: "ch1", pass: ReviewPass(id: "line", name: "Line"), current: current)
            XCTAssertEqual(menu.run.title, "Run Lish\u{2019}s round",
                           "\(String(describing: current)) must still offer its "
                           + "round")
        }
    }

    /// **The four rulings are untouched by the widening.** The menu is the run
    /// verb *and* `chipMenuItems`' own list — the same values, in the same
    /// order, checkmarked the same way — rather than a second list that could
    /// disagree with the one every other test in this section drives.
    func test_theRulingsBesideTheRoundAreTheSameFourVerbsAsEver() {
        let pass = ReviewPass(id: "line", name: "Line")
        let menu = verbs.chipMenu(for: "ch1", pass: pass, current: .done)
        let items = verbs.chipMenuItems(for: "ch1", passId: pass.id, current: .done)

        XCTAssertEqual(menu.states.map(\.title), items.map(\.title))
        XCTAssertEqual(menu.states.map(\.state), items.map(\.state))
        XCTAssertEqual(menu.states.map(\.isCurrent), items.map(\.isCurrent))
        XCTAssertEqual(menu.states.filter(\.isCurrent).map(\.state), [.done],
                       "premise: the cell's own state is still the checkmarked "
                       + "one beside the round")
    }

    // MARK: - Mounted: the click

    /// **A chip click carries the cell's own identity** — the piece from its
    /// row, the pass from its column. Driven at the SECOND piece's THIRD pass so
    /// neither id could be the first of anything, and through a real click on
    /// the mounted control rather than by calling the closure: writing the
    /// binding from the test would prove nothing about whether the chip can be
    /// reached at all.
    func test_aChipClickCarriesItsOwnCellsIdentity() async throws {
        let structure = [
            doc("ch1", "Chapter One"),
            doc("ch2", "Chapter Two"),
        ]
        let window = mount(structure: structure)
        let chips = try await orderedChipsSettling(in: window,
                                                   expecting: 2 * Self.passes.count)

        // Row 2 (`ch2`), column 3 (`copyedit`) — read off the layout the board
        // actually got, so a display that laid the grid out differently fails
        // loudly here rather than clicking whatever is at a hardcoded index.
        let cell = chips[Self.passes.count + 2]
        await click(cell, in: window, until: { !self.calls.navigations.isEmpty })

        XCTAssertEqual(calls.navigations,
                       [BoardClick(piece: "ch2", pass: Self.passes[2].id)],
                       "the click must carry the chip's OWN two ids — never a "
                       + "piece read back out of some selection state, which on "
                       + "a grid is always the wrong piece")
        XCTAssertTrue(calls.writes.isEmpty, "a click rules on nothing")
    }

    /// **A reference row has nothing to click anywhere on it.** Its chips are
    /// absent (asserted above), and the row must not have quietly become a
    /// control of its own instead: a reviewer aiming at the pass columns of a
    /// piece reviewed elsewhere lands on the row itself.
    ///
    /// Swept rather than aimed — the board is a project holding ONLY the
    /// reference, so every point in the column is fair game and the test needs
    /// no row geometry to be right about.
    func test_aReferenceRowOffersNothingToClickAnywhereOnIt() async throws {
        let window = mount(structure: [doc("ref", "Another Novel", kind: .reference)])
        pump(0.3)
        XCTAssertTrue(chips(in: window).isEmpty, "premise: no chips at all")

        await sweepClicks(over: window)

        XCTAssertTrue(calls.navigations.isEmpty,
                      "a reference row offered a click — its passes belong to "
                      + "the project it points at, and a control here would be "
                      + "a decision made in the wrong window")
        XCTAssertTrue(calls.writes.isEmpty)
    }

    /// The control the sweep above needs to mean anything: the same sweep over
    /// the same board with the piece LOOSE does reach a chip. Without it, a
    /// board that mounted nothing at all — or a sweep that missed the column
    /// entirely — would read exactly like a reference row behaving.
    func test_control_theSameSweepOverALoosePieceDoesReachAChip() async throws {
        let window = mount(structure: [doc("ref", "Another Novel", kind: .loose)])
        _ = try await chipsSettling(in: window, expecting: Self.passes.count)

        await sweepClicks(over: window)

        XCTAssertFalse(calls.navigations.isEmpty,
                       "the sweep never reached a chip, so the reference row's "
                       + "silence above is about the sweep and not about the row")
        XCTAssertTrue(calls.navigations.allSatisfy { $0.piece == "ref" })
    }

    // MARK: - The coach is never a column (two loops P1 Task 8)

    /// **The standing guarantee the seat row's three tests were really
    /// about.** The board is the ladder and only the ladder: the coach reads
    /// CHECKS in Author (`AuthorReader`) and a round is a stage editor's, so
    /// nothing about her belongs on a surface whose whole subject is where a
    /// piece stands on each pass.
    ///
    /// She stays out by construction rather than by a filter here — she is
    /// absent from `effectiveReviewPasses`, in every state of the manifest —
    /// which is also why `ActivePassMemory.validatedActivePass` refuses her id
    /// and why the cockpit's picker can never offer her.
    func test_theCoachIsNeverAColumn() {
        let uncustomized = ProjectManifest(
            type: .novel, title: "P", author: "A", created: Date(),
            modified: Date(), structure: [], research: [])
        XCTAssertFalse(
            uncustomized.effectiveReviewPasses.contains {
                $0.id == ReviewPass.coachPreset.id
            },
            "the four presets are the ladder \u{2014} got "
            + "\(uncustomized.effectiveReviewPasses.map(\.id))")

        var customized = uncustomized
        customized.reviewPasses = [
            ReviewPass(id: "line", name: "Line"),
            ReviewPass(id: "polish", name: "Polish")
        ]
        XCTAssertFalse(
            customized.effectiveReviewPasses.contains {
                $0.id == ReviewPass.coachPreset.id
            },
            "\u{2026}and a writer's own ladder is still a ladder of stages")

        var emptied = uncustomized
        emptied.reviewPasses = []
        XCTAssertFalse(
            emptied.effectiveReviewPasses.contains {
                $0.id == ReviewPass.coachPreset.id
            },
            "\u{2026}and an emptied list projects back to the presets, not to "
            + "a board with the coach on it")
    }

    // MARK: - Mounted: one chip per (piece × pass)

    /// **The grid is a grid.** Three pieces, four passes, twelve chips — and
    /// the count is exact, so a row that quietly drew a fifth control (or
    /// skipped a pass whose state is absent) fails here.
    func test_everyPieceGetsOneChipPerPass() async throws {
        let structure = [
            doc("ch1", "Chapter One", states: ["structural": .done]),
            doc("ch2", "Chapter Two"),
            doc("ch3", "Chapter Three", states: ["line": .inProgress, "proof": .skipped]),
        ]
        let window = mount(structure: structure)

        let chips = try await chipsSettling(in: window, expecting: 3 * Self.passes.count)
        XCTAssertEqual(chips.count, 12,
                       "three pieces × four passes. A chip is drawn for an "
                       + "UNTOUCHED pass too — an absent key is a state the "
                       + "reviewer can act on, not a missing cell")
    }

    /// **Group headers are rows, not chips.** Adding two groups around the same
    /// pieces changes nothing about the chip count — the headers carry no
    /// controls of their own (Task 8's navigation is not this task's).
    func test_groupHeadersAddRowsAndNoChips() async throws {
        let flat = mount(structure: [doc("ch1", "One"), doc("ch2", "Two")])
        let flatChips = try await chipsSettling(in: flat, expecting: 2 * Self.passes.count)

        let nested = mount(structure: [
            group("p1", "Part One", [doc("ch1", "One")]),
            group("p2", "Part Two", [group("p2a", "Act I", [doc("ch2", "Two")])]),
        ])
        let nestedChips = try await chipsSettling(in: nested, expecting: 2 * Self.passes.count)

        XCTAssertEqual(nestedChips.count, flatChips.count,
                       "the same two pieces under three group headers must "
                       + "still be eight chips")
    }

    /// **A reference piece is chip-less** — its passes belong to the project it
    /// points at, and a control here would be a decision made in the wrong
    /// window. Asserted as a difference: the same board with the reference
    /// swapped for a loose piece gains a full row of chips.
    func test_aReferenceRowDrawsNoChipsAndALoosePieceInItsPlaceDoes() async throws {
        let withReference = mount(structure: [
            doc("ch1", "Chapter One"),
            doc("ref", "Another Novel", kind: .reference),
        ])
        let referenceChips = try await chipsSettling(
            in: withReference, expecting: Self.passes.count)
        XCTAssertEqual(referenceChips.count, Self.passes.count,
                       "only the loose piece's row carries chips")

        let withLoose = mount(structure: [
            doc("ch1", "Chapter One"),
            doc("ref", "Another Novel", kind: .loose),
        ])
        let looseChips = try await chipsSettling(
            in: withLoose, expecting: 2 * Self.passes.count)
        XCTAssertEqual(looseChips.count, 2 * Self.passes.count,
                       "control: the same row as a LOOSE piece does carry them, "
                       + "so the absence above is about `pieceKind` and not "
                       + "about a row that failed to mount at all")
    }

    /// **The empty project draws no chips and no grid** — the
    /// `ContentUnavailableView` arm. (That it carries tripwire 15's full frame
    /// chain is enforced for every pane under `Maugham/` by
    /// `TripwireGrepTests.test_contentUnavailableViewAlwaysChainsFullFrame`;
    /// what is asserted here is that the arm is REACHED.)
    func test_anEmptyProjectShowsNoBoardAtAll() async throws {
        let window = mount(structure: [])
        pump(0.3)

        XCTAssertTrue(chips(in: window).isEmpty, "no chips on an empty project")
        XCTAssertTrue(scrollViews(in: window).isEmpty,
                      "…and no scrolling grid either — the pane is showing the "
                      + "unavailable view, which is not a scroller")
    }

    // MARK: - Mounted: the states the chips are showing

    /// The chips publish the state they are drawing, piece and pass named, so a
    /// reviewer on VoiceOver can read the board — and so this test can check
    /// that the RIGHT cell got the right state rather than only counting them.
    ///
    /// Skips by name when no assistive client can attach: a tree that was never
    /// built is not evidence about this view (`InspectorIntentAffordanceTests`'
    /// rule).
    func test_eachChipPublishesItsOwnCellsState() async throws {
        let structure = [
            doc("ch1", "Chapter One", states: ["structural": .done, "line": .inProgress]),
            doc("ch2", "Chapter Two", states: ["proof": .skipped]),
        ]
        let window = mount(structure: structure)
        _ = try await chipsSettling(in: window, expecting: 2 * Self.passes.count)

        let labels = try axButtonLabels(in: window)
        XCTAssertFalse(labels.isEmpty,
                       "the hosted board published no buttons at all, so this "
                       + "test could not fail for the reason it exists")

        for expected in [
            "Chapter One — Structural: \(PassLadder.doneTitle)",
            "Chapter One — Line: \(PassLadder.inProgressTitle)",
            "Chapter One — Copyedit: \(PassLadder.untouchedTitle)",
            "Chapter Two — Proof: \(PassLadder.skipTitle)",
            "Chapter Two — Structural: \(PassLadder.untouchedTitle)",
        ] {
            XCTAssertTrue(labels.contains(expected),
                          "no chip published \u{201C}\(expected)\u{201D}. "
                          + "Published: \(labels.sorted())")
        }
    }

    // MARK: - The open-notes column's truth table (no window)

    /// A piece with nothing open draws NOTHING — not a zero. A board of zeros
    /// hides the two numbers that matter, and the column exists to say where
    /// the unanswered feedback is.
    func test_aPieceWithNoOpenNotesDrawsAnEmptyCell() {
        let cell = ReviewBoardOpenNotes.cell(
            piece: "Chapter One", summary: nil, isUnreadable: false,
            passes: Self.passes)
        XCTAssertEqual(cell.kind, .none)
        XCTAssertEqual(cell.text, "")
        XCTAssertEqual(cell.label, "",
                       "nothing drawn says nothing aloud either")
    }

    /// The count, and the sentence behind it: the piece, the number, and where
    /// those notes were written — the pass split is the reason the column is
    /// worth clicking rather than just worth reading.
    func test_theCountCarriesItsPassBreakdown() {
        let cell = ReviewBoardOpenNotes.cell(
            piece: "Chapter One",
            summary: OpenNotesSummary(total: 3, byPass: ["line": 2]),
            isUnreadable: false, passes: Self.passes)

        XCTAssertEqual(cell.kind, .count)
        XCTAssertEqual(cell.text, "3")
        XCTAssertEqual(cell.label, "Chapter One — 3 open notes: 2 Line, 1 unstamped",
                       "the split names passes the way the project does and "
                       + "accounts for the remainder — the two numbers must "
                       + "never silently disagree")
    }

    /// Passes are named in the PROJECT's order, not the dictionary's, and the
    /// unstamped remainder is last: the split reads like the board's own
    /// columns.
    func test_theBreakdownFollowsTheProjectsPassOrder() {
        let cell = ReviewBoardOpenNotes.cell(
            piece: "Chapter One",
            summary: OpenNotesSummary(
                total: 6, byPass: ["proof": 1, "structural": 3, "line": 2]),
            isUnreadable: false, passes: Self.passes)
        XCTAssertEqual(cell.label,
                       "Chapter One — 6 open notes: 3 Structural, 2 Line, 1 Proof")
    }

    /// Nothing stamped is the default state of every project that has not
    /// started using passes — and "3 open notes: 3 unstamped" tells the writer
    /// nothing they did not just read.
    func test_anEntirelyUnstampedPieceSaysJustTheCount() {
        let cell = ReviewBoardOpenNotes.cell(
            piece: "Chapter One",
            summary: OpenNotesSummary(total: 1, byPass: [:]),
            isUnreadable: false, passes: Self.passes)
        XCTAssertEqual(cell.text, "1")
        XCTAssertEqual(cell.label, "Chapter One — 1 open note",
                       "singular, and no split worth the words")
    }

    /// A stamp naming a pass the project no longer lists still counts. It is in
    /// the total, so dropping it from the split would make the sentence add up
    /// to less than the number beside it, with nothing to say why.
    func test_aStampForARetiredPassIsCountedRatherThanDropped() {
        let cell = ReviewBoardOpenNotes.cell(
            piece: "Chapter One",
            summary: OpenNotesSummary(total: 2, byPass: ["line": 1, "sensitivity": 1]),
            isUnreadable: false, passes: Self.passes)
        XCTAssertEqual(cell.label, "Chapter One — 2 open notes: 1 Line, 1 sensitivity")
    }

    /// **The coach's lane is named, not spelled** (editorial letter P1, Task 6).
    ///
    /// She files rounds under her own lane id and is deliberately absent from
    /// `effectiveReviewPasses`, so the retired-pass arm above catches her:
    /// without the resolution this tooltip reads "1 workshop", a schema key on
    /// screen where an editor's name belongs. The word is her EDITOR name, not
    /// her pass name — "Workshop" is on no surface a writer has ever seen. Her
    /// split comes after the project's own passes and before the unstamped
    /// remainder: she is not a column and has no place in the board's order.
    func test_theCoachsNotesAreNamedRatherThanSpelledAsAnId() {
        let cell = ReviewBoardOpenNotes.cell(
            piece: "Chapter One",
            summary: OpenNotesSummary(
                total: 3, byPass: ["line": 1, ReviewPass.coachPreset.id: 2]),
            isUnreadable: false, passes: Self.passes)
        XCTAssertEqual(cell.label, "Chapter One \u{2014} 3 open notes: 1 Line, 2 Le Guin")
        XCTAssertFalse(cell.label.contains("workshop"),
                       "the raw lane id must never be writer-visible copy")
        XCTAssertFalse(cell.label.contains("Workshop"),
                       "\u{2026}and neither is her pass name, which names no "
                       + "column, no ladder row and nothing in the guide")
    }

    /// **Vacating the seat does not unname the notes she already wrote**
    /// (Denver's ruling, Task 6 fix round). A stamp says who WROTE a note and
    /// that cannot be revoked later — not by vacating the seat, and not by
    /// taking the seat off this board (two loops P1 Task 8).
    ///
    /// The cell is built through the same call the pane makes, which has no
    /// seat argument to pass — that absence IS the ruling.
    func test_aVacatedSeatStillNamesHerOldNotes() {
        let cell = ReviewBoardOpenNotes.cell(
            piece: "Chapter One",
            summary: OpenNotesSummary(
                total: 2, byPass: [ReviewPass.coachPreset.id: 2]),
            isUnreadable: false, passes: Self.passes)
        XCTAssertEqual(cell.label, "Chapter One \u{2014} 2 open notes: 2 Le Guin",
                       "her name outlives her seat")
    }

    /// **RULING-54's honesty half, in one cell.** The walk skips a document
    /// whose op log it cannot read rather than throwing the whole count away —
    /// so this piece's cell must say UNKNOWN. A zero here would be the board
    /// asserting "nothing to answer" about a file it could not open.
    func test_anUnreadablePieceSaysUnknownAndNotZero() {
        let cell = ReviewBoardOpenNotes.cell(
            piece: "Chapter Three", summary: nil, isUnreadable: true,
            passes: Self.passes)

        XCTAssertEqual(cell.kind, .unreadable)
        XCTAssertEqual(cell.text, "\u{2014}")
        XCTAssertTrue(cell.label.contains("Chapter Three"))
        XCTAssertTrue(cell.label.contains("could not be read"),
                      "the help string must name the FILE problem, not just "
                      + "shrug: \(cell.label)")
        XCTAssertFalse(cell.text.contains("0"))
    }

    /// The two inputs cannot both arrive today (`openNotesSummaries` keys only
    /// the pieces it could read), which is exactly why the precedence is
    /// asserted rather than assumed.
    func test_unreadableWinsOverAStaleCount() {
        let cell = ReviewBoardOpenNotes.cell(
            piece: "Chapter Three",
            summary: OpenNotesSummary(total: 9, byPass: [:]),
            isUnreadable: true, passes: Self.passes)
        XCTAssertEqual(cell.kind, .unreadable)
        XCTAssertFalse(cell.text.contains("9"))
    }

    // MARK: - Mounted: the open-notes column

    /// The counts reach the board as VALUES and land on the right rows.
    ///
    /// Read off the accessibility tree, which is where the count's whole
    /// sentence lives — the cell itself is a bare number, and a number in a
    /// grid says nothing on its own.
    func test_eachPiecesCountIsPublishedOnItsOwnRow() async throws {
        let structure = [doc("ch1", "Chapter One"), doc("ch2", "Chapter Two"),
                         doc("ch3", "Chapter Three")]
        let window = mount(
            structure: structure,
            openNotes: ["ch1": OpenNotesSummary(total: 3, byPass: ["line": 2]),
                        "ch3": OpenNotesSummary(total: 1, byPass: [:])],
            unreadable: [])
        // Three rows of chips plus the two counted cells.
        _ = try await chipsSettling(in: window,
                                    expecting: 3 * Self.passes.count + 2)

        let labels = try axButtonLabels(in: window)
        XCTAssertTrue(labels.contains("Chapter One — 3 open notes: 2 Line, 1 unstamped"),
                      "published: \(labels.sorted())")
        XCTAssertTrue(labels.contains("Chapter Three — 1 open note"))
        XCTAssertFalse(labels.contains { $0.contains("Chapter Two — 0") },
                       "a piece with nothing open must draw no count at all")
    }

    /// The absent entry is an EMPTY cell and not a control: the exact chip
    /// count is what says so, since a count cell is the only other button the
    /// board has.
    func test_aPieceWithNothingOpenAddsNoControl() async throws {
        let structure = [doc("ch1", "Chapter One"), doc("ch2", "Chapter Two")]
        let window = mount(structure: structure,
                           openNotes: ["ch1": OpenNotesSummary(total: 2, byPass: [:])])
        let found = try await chipsSettling(
            in: window, expecting: 2 * Self.passes.count + 1)

        XCTAssertEqual(found.count, 2 * Self.passes.count + 1,
                       "one count cell for the counted piece and none for the "
                       + "other — an empty cell is not a button")
    }

    /// **Clicking a count carries the ROW's own piece id**, like every other
    /// control on this board, and rules on nothing.
    func test_aCountClickCarriesItsOwnRowsPiece() async throws {
        let structure = [doc("ch1", "Chapter One"), doc("ch2", "Chapter Two")]
        let window = mount(structure: structure,
                           openNotes: ["ch2": OpenNotesSummary(total: 4, byPass: [:])])
        let all = try await orderedChipsSettling(
            in: window, expecting: 2 * Self.passes.count + 1)

        // The counted row is the second, and its count is the last cell across
        // it — read off the layout the board actually got.
        let count = try XCTUnwrap(all.last)
        await click(count, in: window, until: { !self.calls.opened.isEmpty })

        XCTAssertEqual(calls.opened, ["ch2"])
        XCTAssertTrue(calls.navigations.isEmpty,
                      "a count is not a chip: it must not navigate a pass")
        XCTAssertTrue(calls.writes.isEmpty, "and it rules on nothing")
    }

    /// **An unreadable piece's cell is not a control.** "Open the notes we
    /// could not read" is a button that cannot do what it offers; the honest
    /// affordance is the dash and a tooltip saying why.
    func test_anUnreadablePieceOffersNoClick() async throws {
        let window = mount(structure: [doc("ch1", "Chapter One")],
                           unreadable: ["ch1"])
        let found = try await chipsSettling(in: window, expecting: Self.passes.count)
        pump(0.2)

        XCTAssertEqual(found.count, Self.passes.count,
                       "the dash must not be a button")
        await sweepClicks(over: window)
        XCTAssertTrue(calls.opened.isEmpty,
                      "an unreadable piece offered a click into notes it "
                      + "cannot show")
    }

    /// A reference row is chip-less AND countless: the notes on the project it
    /// points at are adjudicated in ITS window, and a number here would invite
    /// a click this window cannot honour.
    func test_aReferenceRowCarriesNoCountEither() async throws {
        let window = mount(
            structure: [doc("ref", "Another Novel", kind: .reference)],
            openNotes: ["ref": OpenNotesSummary(total: 7, byPass: [:])])
        pump(0.3)

        XCTAssertTrue(chips(in: window).isEmpty,
                      "the reference row drew a control — it has neither chips "
                      + "nor a count")
        await sweepClicks(over: window)
        XCTAssertTrue(calls.opened.isEmpty)
    }

    // MARK: - Mounted: the two scrolling axes are the pane's

    /// **A wide pass set scrolls INSIDE the pane, and the pane still fits its
    /// column.** Twelve passes against a 520pt column: the grid's content is
    /// wider than the window, and the hosted view is not — which is the
    /// responsive rule (wide content scrolls in its own container; the window
    /// never scrolls horizontally).
    func test_aWidePassSetScrollsInsideThePaneAndNeverWidensTheWindow() async throws {
        let many = (1...12).map { ReviewPass(id: "p\($0)", name: "Pass \($0)") }
        let width: CGFloat = 520
        let window = mount(structure: [doc("ch1", "Chapter One")],
                           passes: many, width: width)
        _ = try await chipsSettling(in: window, expecting: many.count)

        let host = try XCTUnwrap(window.contentView)
        try XCTSkipUnless(host.bounds.width >= 400,
                          "this display mounted a \(host.bounds.size) column, "
                          + "too narrow to ask the question")

        XCTAssertGreaterThan(
            ReviewBoardPane.intrinsicWidth(passCount: many.count), host.bounds.width,
            "premise: twelve pass columns really are wider than this column")

        let widest = scrollViews(in: window)
            .compactMap { $0.documentView?.frame.width }
            .max() ?? 0
        XCTAssertGreaterThan(widest, host.bounds.width,
                             "the grid must be wider than the column and scroll "
                             + "inside it — scrollers: \(scrollViews(in: window).count)")

        for view in [host] + host.subviews {
            XCTAssertLessThanOrEqual(
                view.frame.width, host.bounds.width + 0.5,
                "the pane itself grew past the column it was given "
                + "(\(view.frame.width) > \(host.bounds.width)), which is the "
                + "window scrolling horizontally")
        }
    }

    /// A narrow pass set does not leave a gutter: the slack goes to the piece
    /// column instead, so the rows fill the pane they are given.
    func test_aNarrowPassSetHandsItsSlackToThePieceColumn() {
        let wideColumn: CGFloat = 900
        XCTAssertLessThan(ReviewBoardPane.intrinsicWidth(passCount: 4), wideColumn,
                          "premise: four passes want less than a 900pt column")
        XCTAssertEqual(
            ReviewBoardPane.intrinsicWidth(passCount: 12),
            ReviewBoardPane.minimumTitleColumnWidth
                + 12 * ReviewBoardPane.passColumnWidth
                + ReviewBoardPane.openNotesColumnWidth,
            "the intrinsic width is the piece column's floor plus every pass "
            + "column plus the open-notes column (M3 P2 Task 9) — the number "
            + "the pane compares its own width against, and a trailing column "
            + "left out of it is a column drawn off the end of the grid")
    }

    // MARK: - Censuses

    /// **The pane reads no store** (tripwire 4, by construction). The board's
    /// body runs once per row on a project that can hold hundreds; a
    /// `ProjectStore` in scope is an invitation to a word count, a document
    /// lookup or a disk read on that path. The pane's inputs are values, and
    /// this is what says so — the mounted tests above cannot, because they
    /// would pass just as well with an unused store property.
    func test_theSourceReadsNoStoreAtAll() throws {
        let code = try Self.codeLines(of: "Views/Review/ReviewBoardPane.swift")

        for forbidden in ["ProjectStore", "DocumentStore", "Document(", "FileManager",
                          "cachedWordCount", "contentsOf"] {
            XCTAssertFalse(code.contains { $0.contains(forbidden) },
                           "`\(forbidden)` appears on the pane's path — the "
                           + "board takes values so nothing per-row can reach "
                           + "the disk (tripwire 4)")
        }
    }

    /// **The chips are `Button`s, never `.onTapGesture`** (tripwire 9's shape,
    /// and `CorkboardGrid`'s), and the board accepts no drops — a reviewer
    /// dragging a chapter onto a pass column means nothing, and a silent
    /// drop target that does nothing is worse than none.
    func test_theBoardUsesButtonsAndAcceptsNoDrops() throws {
        let code = try Self.codeLines(of: "Views/Review/ReviewBoardPane.swift")

        XCTAssertTrue(code.contains { $0.contains("buttonStyle(.plain)") },
                      "the chip must be a plain `Button`")
        for forbidden in ["onTapGesture", "dropDestination", "onDrop", "onInsert"] {
            XCTAssertFalse(code.contains { $0.contains(forbidden) },
                           "the board must not use `\(forbidden)`")
        }
    }

    /// **The container is a `ScrollView`, not a `List`** — and this is not
    /// stylistic. `ReviewBoardRoutingTests.boardScroller` identifies the board
    /// structurally as a scroll view holding NO `NSTableView`, which is what
    /// Task 6's whole routing suite reads; a `List` mounts one and every
    /// routing assertion silently starts finding a different view. If a later
    /// task genuinely wants a `List` here, that reading must be re-derived in
    /// the same commit.
    func test_theBoardIsAScrollViewAndNotAList() throws {
        let code = try Self.codeLines(of: "Views/Review/ReviewBoardPane.swift")

        XCTAssertTrue(code.contains { $0.contains("ScrollView(") })
        XCTAssertTrue(code.contains { $0.contains("LazyVStack") },
                      "rows are lazy — a long manuscript must not build every "
                      + "row view to show the first screenful")
        XCTAssertFalse(code.contains { $0.contains("List(") || $0.contains("List {") },
                       "a `List` mounts an `NSTableView` and breaks "
                       + "`ReviewBoardRoutingTests.boardScroller`")
    }

    /// **The link every menu test in this file borrows, pinned** (M4 P2 Task
    /// 4, and `ReviewRoundCockpitTests`' picker census before it).
    ///
    /// `.contextMenu` builds its `NSMenu` on the right-click itself and is
    /// unreachable headless — which is the whole reason the truth table lives
    /// in `chipMenuItems`/`chipMenu`. That substitution is honest only while
    /// the menu actually calls them: rewiring the chip's menu to a second
    /// spelling, or dropping the run verb from the drawn menu entirely, leaves
    /// every truth-table test above green over a menu nobody can reach.
    ///
    /// So the link is a census over the chip's own declaration. It is the
    /// weakest seam in this task and it is the one worth guarding.
    func test_theChipsMenuDrawsTheVerbsItsTestsDriveInItsPlace() throws {
        let source = try Self.source(of: "Views/Review/ReviewBoardPane.swift")
        let chip = try XCTUnwrap(
            Self.declaration(named: "private func chip(item:", in: source),
            "the chip must still be a readable declaration for this census to "
            + "have a subject")

        XCTAssertTrue(chip.contains("chipMenu(for: item.id, pass: pass, current: state)"),
                      "the drawn menu must come from the factory the tests "
                      + "drive, asked about THIS cell. Got:\n\(chip)")
        XCTAssertTrue(chip.contains("menu.run.perform()"),
                      "\u{2026}and the first item must perform the run verb, or "
                      + "`test_theRoundVerbCarriesItsOwnCell` proves nothing "
                      + "about this control")
        XCTAssertTrue(chip.contains("ForEach(menu.states)"),
                      "\u{2026}and the four rulings must be drawn from the same "
                      + "menu value, not from a second call that could disagree")
        XCTAssertTrue(chip.contains("Divider()"),
                      "a round and a ruling are different acts \u{2014} the menu "
                      + "separates them")
    }

    /// **The window's run-from-chip closure, which no mount can see** (M4 P2
    /// Task 4). Three things have to happen in it and the third is the one that
    /// is easy to leave out: the pass is recorded through the window's ONE
    /// writer, the subject moves to the piece, and the run WAITS for that piece
    /// to be open.
    ///
    /// `CompilerOrchestrator.runRequested` refuses silently while
    /// `environment.reading(docId)` is `nil`, and opening a document is async —
    /// so a mount that called it straight from this closure would do nothing at
    /// all, with no error anywhere. That refusal is pinned as a live hazard in
    /// `CompilerRunCommandTests`; this is what keeps the mount on the far side
    /// of it.
    func test_theProductionMountDefersTheChipsRunUntilThePieceIsOpen() throws {
        let window = try Self.source(of: "Views/ProjectWindow.swift")
        let arm = try XCTUnwrap(window.range(of: "onRunRound:"),
                                "the mount must supply the chip's run closure")
        let after = String(window[arm.upperBound...].prefix(600))

        XCTAssertTrue(after.contains("recordActivePass(forPiece:"),
                      "the round's lane is recorded through the window's one "
                      + "`ActivePassMemory` writer \u{2014} got: \(after)")
        XCTAssertTrue(after.contains("selectedSubject = .item(pieceId)"),
                      "\u{2026}and the writer travels to the piece being checked")
        XCTAssertTrue(after.contains("runRoundWhenPieceOpens("),
                      "\u{2026}and the run goes through the bounded deferral")
        XCTAssertFalse(after.contains("runRequested("),
                       "the chip must NOT call the orchestrator straight from "
                       + "this closure: the document is not open yet and the "
                       + "refusal is silent \u{2014} got: \(after)")

        // **One hop further, because a name is not a behaviour.** The four
        // assertions above are satisfied by a `runRoundWhenPieceOpens` whose
        // body is a bare `runRequested` — the "surely it is open by now"
        // simplification, which is exactly the defect the deferral exists to
        // prevent and which no other test in the suite can see. So the census
        // reads the helper too.
        let helper = try XCTUnwrap(
            Self.declaration(named: "private func runRoundWhenPieceOpens(", in: window),
            "the deferral's one production caller must still be a readable "
            + "declaration for this census to have a subject")
        XCTAssertTrue(helper.contains("RunWhenDocumentOpens.start("),
                      "the helper must go through the bounded wait rather than "
                      + "run outright. Got:\n\(helper)")
        XCTAssertTrue(helper.contains("document(forDocId:"),
                      "\u{2026}and what it waits ON is the piece being OPEN \u{2014} "
                      + "a wait on anything else is a sleep with a nicer name. "
                      + "Got:\n\(helper)")
        // Deliberately no `runRequested`-absence assertion here: this helper's
        // whole job is to end at that call, inside `start`'s `run:` closure.
    }

    /// The one production mount hands the pane values off `manifest` — the
    /// other half of the tripwire-4 census, since the pane's own file cannot
    /// see what is passed to it.
    func test_theProductionMountPassesManifestValues() throws {
        let code = try Self.codeLines(of: "Views/ProjectWindow.swift")

        for expected in ["title: store.manifest.title",
                         "structure: store.manifest.structure",
                         "passes: store.manifest.effectiveReviewPasses"] {
            XCTAssertTrue(code.contains { $0.contains(expected) },
                          "the mount must pass `\(expected)`")
        }
    }

    // MARK: - Hosting

    private func mount(structure: [StructureItem],
                       passes: [ReviewPass] = ReviewBoardPaneTests.passes,
                       openNotes: [String: OpenNotesSummary] = [:],
                       unreadable: Set<String> = [],
                       width: CGFloat = 700) -> NSWindow {
        let calls = self.calls
        let window = TestWindow.mount(AnyView(
            ReviewBoardPane(title: "The Project", structure: structure, passes: passes,
                            openNotes: openNotes,
                            unreadableDocIds: unreadable,
                            onOpenNotes: { calls.opened.append($0) },
                            onNavigate: { piece, pass in
                                calls.navigations.append(BoardClick(piece: piece, pass: pass))
                            },
                            onSetState: { piece, pass, state in
                                calls.writes.append(
                                    BoardWrite(piece: piece, pass: pass, state: state))
                            },
                            onRunRound: { piece, pass in
                                calls.runs.append(BoardClick(piece: piece, pass: pass))
                            })
                .frame(maxWidth: .infinity, maxHeight: .infinity)),
            size: CGSize(width: width, height: 600))
        windows.append(window)
        pump(0.1)
        return window
    }

    // MARK: - Reading the mounted board

    /// See the class doc: a SwiftUI `Button` mounts a focus-ring container and
    /// no `NSButton`, and the chips are this task's only buttons.
    private func chips(in window: NSWindow) -> [NSView] {
        collect(NSView.self, in: window)
            .filter { String(describing: type(of: $0)).contains("FocusRingView") }
    }

    private func chipsSettling(in window: NSWindow, expecting count: Int,
                               file: StaticString = #filePath,
                               line: UInt = #line) async throws -> [NSView] {
        var found: [NSView] = []
        _ = await pumpUntil(deadline: 5) {
            found = self.chips(in: window)
            return found.count >= count
        }
        // The waits above are for the count to be REACHED; a board that draws
        // too many settles at the wrong number and the caller's exact
        // assertion is what catches it. Give a stray extra a window to appear
        // in before reading.
        pump(0.2)
        found = chips(in: window)
        XCTAssertFalse(found.isEmpty,
                       "the board mounted no chips at all", file: file, line: line)
        return found
    }

    /// The same chips, in the order a reviewer reads them: down the rows, then
    /// across the passes. Sorted by the frame each one GOT rather than by
    /// subview order, so "the second piece's third pass" names the cell on
    /// screen whatever the layout did with the width this display granted
    /// (`ProjectAltitudeCentreTests.cards`' rule).
    private func orderedChips(in window: NSWindow) -> [NSView] {
        guard let content = window.contentView else { return [] }
        return chips(in: window)
            .map { (view: $0, frame: $0.convert($0.bounds, to: content)) }
            .sorted { a, b in
                if abs(a.frame.midY - b.frame.midY) > 1 { return a.frame.midY < b.frame.midY }
                return a.frame.minX < b.frame.minX
            }
            .map(\.view)
    }

    private func orderedChipsSettling(in window: NSWindow, expecting count: Int,
                                      file: StaticString = #filePath,
                                      line: UInt = #line) async throws -> [NSView] {
        _ = try await chipsSettling(in: window, expecting: count,
                                    file: file, line: line)
        let ordered = orderedChips(in: window)
        XCTAssertEqual(ordered.count, count,
                       "the board drew \(ordered.count) chips, not \(count)",
                       file: file, line: line)
        return ordered
    }

    /// A real click at the centre of a view — down and up through the window, so
    /// the `Button` gets its chance exactly as it does under a mouse
    /// (`ProjectAltitudeCentreTests`' technique, which is what this file's
    /// mounted readings are calibrated against). `until` is the thing the
    /// caller's next assertion reads, so the wait costs what the click really
    /// takes rather than its worst case.
    private func click(_ view: NSView, in window: NSWindow,
                       until settled: (() -> Bool)? = nil) async {
        let centre = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        await click(at: view.convert(centre, to: nil), in: window, until: settled)
    }

    private func click(at inWindow: CGPoint, in window: NSWindow,
                       until settled: (() -> Bool)? = nil) async {
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
        if let settled { _ = await pumpUntil(deadline: 3, settled) }
    }

    /// Click a coarse grid of points over the whole hosted column. Used where
    /// the question is "is there anything clickable HERE at all" rather than
    /// "does this control work" — it needs no row geometry, so it cannot be
    /// wrong about where a row ended up.
    ///
    /// **The vertical pitch is below the board's own row height**, so no grid
    /// row can fall BETWEEN two sample points. It was a flat eight rows over
    /// the window's height until a row above the grid moved everything down by
    /// ~20pt and `test_control_theSameSweepOverALoosePieceDoesReachAChip`
    /// stopped reaching a chip (the seat row, since removed with the seat —
    /// two loops P1 Task 8): a sweep whose resolution is tuned to one layout
    /// reports "nothing clickable" the next time anything above the grid
    /// changes height, and the negative test it controls for goes green for
    /// the wrong reason.
    private func sweepClicks(over window: NSWindow) async {
        guard let content = window.contentView else { return }
        let bounds = content.bounds
        let pitch = ReviewBoardPane.pieceRowHeight - 6
        var y = pitch / 2
        while y < bounds.height {
            for column in 1...5 {
                let point = CGPoint(x: bounds.width * CGFloat(column) / 6, y: y)
                await click(at: content.convert(point, to: nil), in: window)
            }
            y += pitch
        }
        pump(0.2)
    }

    private func scrollViews(in window: NSWindow) -> [NSScrollView] {
        collect(NSScrollView.self, in: window)
    }

    // MARK: - Census helpers

    private static var appSourceDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MaughamTests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Maugham", isDirectory: true)
    }

    private static func codeLines(of relativePath: String) throws -> [String] {
        let url = appSourceDir.appendingPathComponent(relativePath)
        return SourceScan.codeLines(of: try String(contentsOf: url, encoding: .utf8))
    }

    /// The whole file, comments included — the censuses that read a single
    /// declaration need its braces intact, which `codeLines` does not promise.
    private static func source(of relativePath: String) throws -> String {
        try String(contentsOf: appSourceDir.appendingPathComponent(relativePath),
                   encoding: .utf8)
    }

    /// The text from `name` to the end of its brace-balanced body
    /// (`ReviewRoundCockpitTests`' reader, which this file's censuses share).
    private static func declaration(named name: String, in source: String) -> String? {
        guard let start = source.range(of: name) else { return nil }
        var depth = 0
        var index = start.lowerBound
        var seenOpen = false
        while index < source.endIndex {
            let character = source[index]
            if character == "{" { depth += 1; seenOpen = true }
            if character == "}" {
                depth -= 1
                if seenOpen && depth == 0 {
                    return String(source[start.lowerBound...index])
                }
            }
            index = source.index(after: index)
        }
        return nil
    }
}

// MARK: - Recording what the board asked its host to do

/// A chip click's payload: the cell's own two ids.
struct BoardClick: Equatable { let piece: String; let pass: String }

/// A menu verb's payload.
struct BoardWrite: Equatable { let piece: String; let pass: String; let state: PassState? }

/// Deliberately not `@MainActor` and at file scope: the pane's closures are
/// plain function values — nothing about `ReviewBoardPane` requires its host to
/// hand it isolated ones, and a recorder that demanded isolation would be a
/// constraint the test invented rather than one the view has. Everything here
/// still runs on the main thread: the mount, the clicks and the reads are all
/// inside a `@MainActor` test class.
final class BoardCalls: @unchecked Sendable {
    var navigations: [BoardClick] = []
    var writes: [BoardWrite] = []
    /// Pieces whose open-notes count was clicked (M3 P2 Task 9).
    var opened: [String] = []
    /// Cells whose menu asked for a round (M4 P2 Task 4). Same payload shape as
    /// a navigation and deliberately a DIFFERENT list: a run travels *and*
    /// checks, so a recorder that merged the two could not tell the chip's
    /// click from its round.
    var runs: [BoardClick] = []
}
