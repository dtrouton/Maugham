import XCTest
import AppKit
import SwiftUI
import Observation
@testable import Maugham

/// Holds the right column's inputs outside the view, and **counts every write of
/// the width**, so a test can tell a writer's drag from the app moving the
/// divider on its own.
@Observable
@MainActor
final class DetailColumnProbe {
    /// Which spelling the harness applies — the production one, or the range
    /// this task replaced. `.range` exists so the diagnosis is a measurement
    /// this suite keeps making rather than a paragraph in a report.
    enum Spelling { case width, range }

    var mounted: Bool = true
    /// Stands for the pane the right column is showing. `1` is a pane whose
    /// content wants to be wider than the column — an Outline table, a
    /// Diagnostics row, any label that will not break.
    var pane: Int = 0
    var visibility: NavigationSplitViewVisibility = .all

    /// The window content's width, measured by production's own
    /// `ContainerWidthReporter` rather than by anything this file computes.
    /// `nil` until the first measurement lands, exactly as in `ProjectWindow`.
    private(set) var containerWidth: Double?

    /// **Through production's guard, not around it.** This used to be a bare
    /// `probe.containerWidth = $0` on the reporter, which is why sixteen green
    /// tests could not see a memo that never recorded anything: production's
    /// `noteContainerWidth` was exercised by nothing at all. Two lines,
    /// mirroring that method exactly, and the predicate is asked of
    /// `ProjectWindow` rather than restated.
    func noteContainerWidth(_ width: Double) {
        guard ProjectWindow.recordsContainerWidth(width, over: containerWidth) else { return }
        containerWidth = width
    }

    /// The writer's WISH — what `UIState` stores. What the column is given is
    /// `ProjectWindow.effectiveDetailColumnWidth` of this and the container, and
    /// keeping the two spelled apart here is how a test can assert that the
    /// window reduces one without ever touching the other.
    private(set) var widthWrites: Int = 0
    var width: Double {
        didSet { widthWrites += 1 }
    }

    init(width: Double = 320, spelling: Spelling = .width) {
        self.width = width
        self.spelling = spelling
        self.widthWrites = 0
    }

    let spelling: Spelling
}

/// The right column composed the way `ProjectWindow.detailColumn` composes it:
/// a three-column `NavigationSplitView`, the detail column mounted behind a
/// `if showInspector`, and the pane's content swapped underneath.
@MainActor
private struct DetailColumnHarness: View {
    let probe: DetailColumnProbe

    var body: some View {
        NavigationSplitView(columnVisibility: Binding(
            get: { probe.visibility }, set: { probe.visibility = $0 })) {
            // The production floors, asked of production rather than restated —
            // the affordability sum reasons about these two numbers, so a
            // harness carrying its own copies would be measuring a different
            // window than the one the sum is about.
            Color.gray.navigationSplitViewColumnWidth(
                min: ProjectWindow.binderColumnFloor, ideal: 240)
        } content: {
            Color.white.navigationSplitViewColumnWidth(
                min: ProjectWindow.centreColumnFloor, ideal: 720)
        } detail: {
            if probe.mounted { detailColumn }
        }
        .modifier(ContainerWidthReporter(onWidth: { probe.noteContainerWidth($0) }))
    }

    @ViewBuilder
    private var detailColumn: some View {
        switch probe.spelling {
        case .width:
            pane.navigationSplitViewColumnWidth(
                ProjectWindow.effectiveDetailColumnWidth(
                    persisted: probe.width, containerWidth: probe.containerWidth))
        case .range:
            pane.navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        }
    }

    /// Three panes, and the third is load-bearing: pane `2` is a *different*
    /// view of the *same* narrow intrinsic width, which is how
    /// `test_neitherAPaneSwapNorAHideShowIsWhatMovedIt` separates "the identity
    /// changed" from "the content asked for more room".
    @ViewBuilder
    private var pane: some View {
        VStack(spacing: 0) {
            switch probe.pane {
            case 0:
                Text("Inspector")
            case 1:
                Text("a label this pane will not break, wanting far more width "
                     + "than the column was dragged to")
                    .fixedSize()
            default:
                Text("History")
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// **One width, held through every persona and every pane switch.**
///
/// Denver, 2026-08-08: *"I hate that the right hand column keeps shifting widths
/// as I change modes, that needs to stop."*
///
/// **The mechanism, measured before anything was fixed** (macOS 26.5, 2026-08-08
/// — and note CLAUDE.md's runner-parity rule: these mount real AppKit views, so
/// a green run here says nothing about a runner on a different major).
/// `ProjectWindow` had exactly one `navigationSplitViewColumnWidth` on the
/// detail column and the width still moved, because **a range is not a width**.
/// `min:ideal:max:` declares the interval AppKit may resolve a divider inside,
/// and it re-resolves whenever something re-proposes. Two things do, and neither
/// is a view-identity change — the hypothesis this task opened with, falsified
/// here by `test_neitherAPaneSwapNorAHideShowIsWhatMovedIt`:
///
/// | what the writer did | dragged to | landed on |
/// |---|---|---|
/// | switched to a pane with wider content | 329 | 360 — the range's `max` |
/// | `⌘\` on the canvas and back (`.doubleColumn` → `.all`) | 329 | 240 — the range's `min` |
///
/// The fix is the single-argument spelling, and the honest claim for it is that
/// it holds through both — measured, rather than true by construction. An
/// unbreakable pane still raises a real constraint conflict that AppKit resolves
/// in the column's favour by its own undocumented tie-breaking; see
/// `test_theFixedColumnWinsAgainstAnUnbreakablePane`, which is the canary on
/// that. `test_plantedOffender_theRangeIsWhatMovedIt` keeps both rows of the
/// table above measurable, so the diagnosis cannot rot into a comment nobody can
/// check.
///
/// **The width that is APPLIED is not the width that is stored.** The three
/// columns' floors can out-arithmetic the window's own, and when they do the
/// right column is reduced to what the window affords rather than the window
/// being grown — see `ProjectWindow.effectiveDetailColumnWidth` and
/// `test_theWidestWishDoesNotGrowTheNarrowestWindow`. The stored wish is never
/// touched by that.
///
/// **What this harness is and is not.** It mounts a real `NavigationSplitView`
/// with the real modifier, so what it measures is AppKit's behaviour rather than
/// Maugham's. What ties it to production is the census at the bottom of this
/// file: the harness proves the spelling holds, the census proves the app uses
/// that spelling and writes the width from one place.
@MainActor
final class DetailColumnWidthTests: XCTestCase {

    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        for window in windows { window.contentView = NSView(frame: .zero) }
        settle(0.05)
        windows.removeAll()
    }

    // MARK: - The width survives what a mode change does to this column

    /// A persona switch reaches this column through three observable signals,
    /// and it can fire all three in one press: `PersonaModifier` restores the
    /// destination's remembered pane (the content swaps), forces
    /// `showInspector = true` (the column may be re-mounted), and hands
    /// `columnVisibility` back to `.all` after a canvas collapse. All three are
    /// driven here, in that order, and the writer's 320 must come out the far
    /// side.
    func test_theWidthSurvivesAPersonaRoundTrip() async throws {
        let probe = DetailColumnProbe(width: 320)
        let (_, split) = try await mount(probe)
        XCTAssertEqual(width(of: split), 320, accuracy: 1,
                       "premise: the column opens at the writer's own width")

        for pane in [1, 2, 0] {
            probe.pane = pane
            probe.mounted = false
            await pump(0.5)
            probe.mounted = true
            probe.visibility = .doubleColumn
            await pump(0.5)
            probe.visibility = .all
            await pump(0.6)

            XCTAssertEqual(width(of: split), 320, accuracy: 1,
                           "pane \(pane): a mode change may move what the column "
                           + "SHOWS and must never move how wide it is")
        }
    }

    /// The cheaper half of the same rule, on its own: `⌘⌥`-letter pane
    /// shortcuts fire in every persona, and the pane they land on is the one
    /// whose content used to push the divider out to `max`.
    func test_theWidthSurvivesAPaneSwitch() async throws {
        let probe = DetailColumnProbe(width: 300)
        let (_, split) = try await mount(probe)

        probe.pane = 1
        await pump(0.7)
        XCTAssertEqual(width(of: split), 300, accuracy: 1,
                       "a pane whose content wants to be wider than the column "
                       + "must be given the column's width, not the other way "
                       + "round")

        probe.pane = 0
        await pump(0.7)
        XCTAssertEqual(width(of: split), 300, accuracy: 1)
    }

    /// **The hypothesis this task opened with, falsified.** The leading guess
    /// was that a view-identity change re-applies the modifier's `ideal`. It
    /// does not: with the RANGE spelling still in place, swapping the pane's
    /// content for one of the same intrinsic width and un-mounting/re-mounting
    /// the whole column both leave a dragged width exactly where it was. What
    /// moved it was the content's width demand and the visibility transition —
    /// which is why the fix is the spelling and not an `.id()`.
    func test_neitherAPaneSwapNorAHideShowIsWhatMovedIt() async throws {
        let probe = DetailColumnProbe(spelling: .range)
        let (_, split) = try await mount(probe)
        let dragged = try await dragDivider(of: split, toDetailWidth: 330)
        XCTAssertLessThan(dragged, 360,
                          "premise: the divider actually moved off the range's "
                          + "max, or this test measures nothing")

        probe.pane = 2      // same intrinsic width as pane 0
        await pump(0.6)
        XCTAssertEqual(width(of: split), dragged, accuracy: 1,
                       "an identity change alone does not re-apply `ideal`")

        probe.mounted = false
        await pump(0.5)
        probe.mounted = true
        await pump(0.6)
        XCTAssertEqual(width(of: split), dragged, accuracy: 1,
                       "and neither does un-mounting the column and putting it "
                       + "back — `showInspector` was never the culprit")
    }

    /// **The planted offender, and the diagnosis it keeps measurable.** The
    /// range spelling this task removed, driven through the same harness: a
    /// wide pane takes the column to the range's `max`, and a visibility round
    /// trip drops it on the range's `min`. If either row of this table ever
    /// stops reproducing, the tests above are passing for a reason nobody has
    /// checked.
    func test_plantedOffender_theRangeIsWhatMovedIt() async throws {
        let probe = DetailColumnProbe(spelling: .range)
        let (_, split) = try await mount(probe)
        let dragged = try await dragDivider(of: split, toDetailWidth: 330)

        probe.pane = 1
        await pump(0.7)
        XCTAssertEqual(width(of: split), 360, accuracy: 1,
                       "the offender: a pane wanting more width takes the "
                       + "column out to the range's max, over a width the "
                       + "writer had dragged to \(dragged)")

        probe.pane = 0
        await pump(0.6)
        probe.visibility = .doubleColumn
        await pump(0.6)
        probe.visibility = .all
        await pump(0.7)
        XCTAssertEqual(width(of: split), 240, accuracy: 1,
                       "and the offender's second half: a columnVisibility "
                       + "round trip — `⌘\\` on the canvas, then any persona "
                       + "switch — lands the column on the range's MIN")
    }

    /// **A canary on AppKit's tie-breaking, not a proof of it.** The tempting
    /// framing — "a range with one value in it has nothing left to re-resolve" —
    /// overclaims. A pane whose content is genuinely unbreakable raises a real
    /// Auto Layout conflict against the fixed column, and the suite logs it:
    ///
    /// ```
    /// Conflicting constraints detected: (
    ///     "NSLayoutGuide.width >= 360   (active)>",
    ///     "'NSSplitViewItem.MaxSize' NSLayoutGuide.width <= 300   (active)>"
    /// )
    /// ```
    ///
    /// AppKit resolves it by breaking the max-size constraint rather than the
    /// content's intrinsic-width demand, which is *why* the column still comes
    /// out at the width it was given. That tie-break is undocumented and not
    /// ours, so this test is here to go red the day it changes — the day a
    /// `.fixedSize()` pane starts winning is the day the fix needs a different
    /// shape. Real Inspector and Outline content wraps or scrolls, so provoking
    /// it takes the deliberate `.fixedSize()` in this harness.
    func test_theFixedColumnWinsAgainstAnUnbreakablePane() async throws {
        let probe = DetailColumnProbe(width: 300)
        let (_, split) = try await mount(probe)

        probe.pane = 1
        await pump(0.8)
        XCTAssertEqual(width(of: split), 300, accuracy: 1,
                       "the column's width must still win the tie against a "
                       + "pane that cannot break — if this goes red, read this "
                       + "test's doc comment before assuming it is a flake")
    }

    // MARK: - Nothing but a drag writes the width

    /// **No feedback loop, structurally.** The other honest route to capturing a
    /// drag is a `GeometryReader` writing the observed width back to ui-state;
    /// with it, every transition above would report a width and write it, and
    /// the writer's number would be whatever the last transition happened to
    /// measure. A fixed column has no geometry of its own to report, so the
    /// count here is zero and the only writer left is the gesture.
    func test_aPersonaSwitchDoesNotWriteTheWidth() async throws {
        let probe = DetailColumnProbe(width: 300)
        let (_, split) = try await mount(probe)
        XCTAssertEqual(probe.widthWrites, 0, "premise: mounting wrote nothing")

        probe.pane = 1
        await pump(0.5)
        probe.mounted = false
        await pump(0.4)
        probe.mounted = true
        probe.visibility = .doubleColumn
        await pump(0.5)
        probe.visibility = .all
        await pump(0.6)

        XCTAssertEqual(probe.widthWrites, 0,
                       "a persona switch, a pane switch and a collapse round "
                       + "trip must write the width exactly never")
        XCTAssertEqual(width(of: split), 300, accuracy: 1)

        // The control: the gesture's own write does reach it, so a probe that
        // simply cannot count is not what the zero above is made of.
        probe.width = 360
        await pump(0.6)
        XCTAssertEqual(probe.widthWrites, 1)
        XCTAssertEqual(width(of: split), 360, accuracy: 1,
                       "and the column follows the value live, which is what "
                       + "makes the handle a resize rather than a jump")
    }

    // MARK: - The store contracts

    func test_theDraggedWidthRoundTripsThroughTheStore() throws {
        let original = UIState(detailColumnWidth: 412)
        let decoded = try JSONDecoder().decode(
            UIState.self, from: try JSONEncoder().encode(original))
        XCTAssertEqual(decoded.detailColumnWidth, 412)
    }

    /// Additive: a file written before this key existed opens at the width the
    /// old range called `ideal`, so nothing moves for a writer who never
    /// touched the divider.
    func test_aFileWithoutTheKeyOpensAtTheOldIdeal() throws {
        let json = """
        {"schemaVersion": \(UIState.currentSchemaVersion)}
        """
        let decoded = try JSONDecoder().decode(
            UIState.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.detailColumnWidth, 280)
        XCTAssertEqual(UIState.defaultDetailColumnWidth, 280)
    }

    /// The clamp is the safety on a value the writer owns, and a hand-edited
    /// `ui-state.json` is a writer of it with no gesture to limit it — so both
    /// ways in clamp, exactly as `assistantColumnWidth` does.
    func test_everyWayInIsClamped() throws {
        let range = UIState.detailColumnWidthRange
        XCTAssertTrue(range.contains(UIState.defaultDetailColumnWidth),
                      "a default outside its own clamp is a default nobody gets")

        XCTAssertEqual(UIState(detailColumnWidth: 4000).detailColumnWidth,
                       range.upperBound)
        XCTAssertEqual(UIState(detailColumnWidth: 10).detailColumnWidth,
                       range.lowerBound)

        for (written, expected) in [(4000.0, range.upperBound), (10.0, range.lowerBound)] {
            let json = """
            {"schemaVersion": \(UIState.currentSchemaVersion), \
            "detailColumnWidth": \(written)}
            """
            let decoded = try JSONDecoder().decode(UIState.self, from: Data(json.utf8))
            XCTAssertEqual(decoded.detailColumnWidth, expected,
                           "a \(written)pt column restored into a window with no "
                           + "room for it is the case the decode clamp is for")
        }
    }

    // MARK: - The window the writer is actually in

    /// **A widest wish must not grow the window.** The three columns' floors
    /// out-arithmetic the window's own — 208 + 480 + 480 is 1168 against a
    /// declared floor of 980 — and AppKit does not resolve that by squeezing
    /// anything: it silently GROWS the window past its own minimum. The first
    /// version of this test asserted the centre column's width at a *nominal*
    /// 980 and never checked that the window it was measuring was 980; it was
    /// 1169. Found by review, 2026-08-08.
    ///
    /// **Every assertion here names the window itself**, before and after, which
    /// is the part that was missing rather than the part that was wrong.
    func test_theWidestWishDoesNotGrowTheNarrowestWindow() async throws {
        let probe = DetailColumnProbe(width: UIState.detailColumnWidthRange.upperBound)
        let (window, split) = try await mount(probe, windowWidth: 980)
        XCTAssertEqual(window.frame.width, 980, accuracy: 1,
                       "premise: the window opened at the floor it was asked "
                       + "for — if it did not, nothing below is about a narrow "
                       + "window at all")

        await pump(0.8)

        XCTAssertEqual(window.frame.width, 980, accuracy: 1,
                       "and it must still be 980 after laying out: a window "
                       + "that grows under a returning writer is this task's "
                       + "own complaint, moved from the divider to the window "
                       + "edge")
        XCTAssertEqual(split.frame.width, window.frame.width, accuracy: 1,
                       "the split view fills the window, so measuring one is "
                       + "measuring the other")

        let expected = ProjectWindow.effectiveDetailColumnWidth(
            persisted: UIState.detailColumnWidthRange.upperBound,
            containerWidth: 980)
        XCTAssertEqual(width(of: split), expected, accuracy: 1,
                       "the column is given what this window can afford — "
                       + "\(expected)pt — and not the 480 that was wished for")

        let centre = try XCTUnwrap(split.arrangedSubviews.dropLast().last?.frame.width)
        XCTAssertGreaterThanOrEqual(centre, Double(ProjectWindow.centreColumnFloor) - 1,
                                    "and the prose keeps its own floor — "
                                    + "measured \(centre)pt")
    }

    /// **The relaunch case, which is the regression path the review named.** A
    /// writer drags the column to 480 on a large display, quits, and reopens the
    /// project on a laptop. The stored 480 must not arrive as a wider window.
    ///
    /// Distinct from the test above in what it drives: there the wish is set
    /// before mounting as a value; here it is the *persisted* value being
    /// restored, and the assertion is about the window rather than the column.
    func test_aWishWiderThanTheWindowDoesNotGrowItOnReopen() async throws {
        let stored = UIState(detailColumnWidth: 480)
        XCTAssertEqual(stored.detailColumnWidth, 480,
                       "premise: the store kept the writer's wish whole")

        let probe = DetailColumnProbe(width: stored.detailColumnWidth)
        let (window, split) = try await mount(probe, windowWidth: 980)
        await pump(0.8)

        XCTAssertEqual(window.frame.width, 980, accuracy: 1,
                       "reopening a project whose stored column is wider than "
                       + "this window can afford must move the window not at all")
        XCTAssertLessThan(width(of: split), 480,
                          "the column gives, because it is the one that can")
        XCTAssertEqual(probe.width, 480,
                       "and the WISH is untouched — the reduction is what is "
                       + "displayed, never what is stored, so the writer gets "
                       + "their 480 back on the display they set it on")
        XCTAssertEqual(probe.widthWrites, 0,
                       "nothing wrote it, either")
    }

    /// The other side of the asymmetry: a window that can afford the whole wish
    /// gives the whole wish. Without this, a clamp that simply always returned
    /// its floor would satisfy every assertion above.
    ///
    /// **The premise is read off the window rather than off what was asked
    /// for.** A requested 1600 came back as 1470 on this machine — `NSWindow`
    /// will not open wider than the screen — which is exactly the class of
    /// silently-different-window this whole fix round is about, arriving from
    /// the other direction. What the test needs is a window that can afford the
    /// wish, not one particular number.
    func test_aWindowWithRoomHonoursTheWholeWish() async throws {
        let probe = DetailColumnProbe(width: 480)
        let (window, split) = try await mount(probe, windowWidth: 1400)
        await pump(0.8)

        let floors = Double(ProjectWindow.binderColumnFloor
                            + ProjectWindow.sidebarInset
                            + ProjectWindow.centreColumnFloor)
        XCTAssertGreaterThanOrEqual(
            Double(window.frame.width), floors + 480,
            "premise: this window can actually afford the whole 480 — it "
            + "opened at \(window.frame.width)pt, and a screen too small for "
            + "that makes the assertion below meaningless rather than wrong")
        XCTAssertEqual(width(of: split), 480, accuracy: 1,
                       "a window with the room gives the writer their whole "
                       + "wish — the reduction is affordability, not policy")
    }

    /// The sum itself, without a window — cheap, exhaustive, and the thing the
    /// mounted tests above are only able to sample.
    func test_theAffordabilitySumGivesTheWindowWhatItNeedsAndTheWriterTheRest() {
        let floors = Double(ProjectWindow.binderColumnFloor
                            + ProjectWindow.sidebarInset
                            + ProjectWindow.centreColumnFloor)

        // Roomy: the wish, whole.
        XCTAssertEqual(ProjectWindow.effectiveDetailColumnWidth(
            persisted: 480, containerWidth: 1600), 480)
        // Tight: reduced to exactly what is left over.
        XCTAssertEqual(ProjectWindow.effectiveDetailColumnWidth(
            persisted: 480, containerWidth: 980), 980 - floors)
        // Never below the column's own floor, however impossible the window.
        XCTAssertEqual(ProjectWindow.effectiveDetailColumnWidth(
            persisted: 480, containerWidth: 400),
                       UIState.detailColumnWidthRange.lowerBound)
        // Never ABOVE the wish — affordability only ever takes away.
        XCTAssertEqual(ProjectWindow.effectiveDetailColumnWidth(
            persisted: 260, containerWidth: 3000), 260)
        // Unmeasured reads as the window's own floor, the conservative answer:
        // a generous guess grows the window before the measurement can arrive,
        // and a grown window does not shrink back on its own.
        XCTAssertEqual(ProjectWindow.effectiveDetailColumnWidth(
            persisted: 480, containerWidth: nil),
                       ProjectWindow.effectiveDetailColumnWidth(
                        persisted: 480,
                        containerWidth: Double(ProjectWindow.windowFloor)))
    }

    /// The measurement is recorded only when it changes what the window can
    /// afford, because a window drag-resize is 60 frames a second and
    /// `ProjectWindow.body` is not something to re-evaluate at that rate.
    func test_aResizeThatChangesNothingIsNotRecorded() {
        XCTAssertFalse(ProjectWindow.recordsContainerWidth(1700, over: 1600),
                       "both afford the whole range, so there is nothing to say")
        XCTAssertTrue(ProjectWindow.recordsContainerWidth(980, over: 1600),
                      "crossing into the squeeze is exactly when it must be said")
    }

    /// **The first measurement always lands when it widens what is affordable —
    /// whatever the writer's current width happens to be.**
    ///
    /// This is the assertion whose opposite this file used to make. It read
    /// `recordsContainerWidth(1600, over: nil, persisted: 260)` must be FALSE,
    /// reasoned as "a narrow wish is afforded everywhere, so there is nothing to
    /// change" — true of the effective width and false of the ceiling, which is
    /// the other consumer of the value being memoized. A test can enshrine a
    /// defect as confidently as it can catch one, and this one did.
    func test_theFirstMeasurementLandsWhateverTheWriterIsCurrentlyAt() {
        for persisted in [UIState.detailColumnWidthRange.lowerBound,
                          UIState.defaultDetailColumnWidth,
                          UIState.detailColumnWidthRange.upperBound] {
            XCTAssertTrue(
                ProjectWindow.recordsContainerWidth(1600, over: nil),
                "a wide window must be recorded on sight — at persisted "
                + "\(persisted) as much as any other, because what the memo "
                + "protects is the CEILING and the ceiling does not depend on "
                + "where the writer currently is")
        }
    }

    // MARK: - Where a drag lands

    /// **The writer's own test, and the one that was missing.** A fresh project
    /// at the default width, on a display with room to spare: hauling the handle
    /// left must reach the range's ceiling, not the fallback the column falls
    /// back to before its window has been measured.
    ///
    /// It failed for the whole of two fix rounds. The container width was
    /// recorded only when it changed the effective width *at the current
    /// persisted value* — and at any width the window already affords, that is a
    /// comparison of a number with itself. So nothing was ever recorded, the
    /// ceiling stayed the unmeasured fallback on every display, and drag-end
    /// persisted a value below it, which kept the guard quiet across every
    /// relaunch. The column could not be dragged as wide as the range it
    /// replaced.
    ///
    /// **This goes through the guard rather than around it**: `probe.containerWidth`
    /// is only non-nil if production's `recordsContainerWidth` said to record
    /// it, and the harness reaches it through the real `ContainerWidthReporter`.
    /// Restore the old predicate and this goes red; every other test in this
    /// file stays green, which is exactly why it needs to exist.
    func test_aFreshProjectOnAWideDisplayCanDragPastTheFallback() async throws {
        let probe = DetailColumnProbe(width: UIState.defaultDetailColumnWidth)
        let (window, _) = try await mount(probe, windowWidth: 1400)
        await pump(0.8)

        let unmeasured = ProjectWindow.draggableDetailCeiling(containerWidth: nil)
        XCTAssertGreaterThanOrEqual(
            Double(window.frame.width),
            Double(ProjectWindow.binderColumnFloor + ProjectWindow.sidebarInset
                   + ProjectWindow.centreColumnFloor)
                + UIState.detailColumnWidthRange.upperBound,
            "premise: this window can afford the whole range — it opened at "
            + "\(window.frame.width)pt")

        let measured = try XCTUnwrap(
            probe.containerWidth,
            "the guard must have recorded a window this much wider than the "
            + "floor — a nil here is the starved memo itself")

        let ceiling = ProjectWindow.draggableDetailCeiling(containerWidth: measured)
        XCTAssertGreaterThan(ceiling, unmeasured,
                             "a measured wide window must afford more than the "
                             + "unmeasured fallback of \(unmeasured)pt")
        XCTAssertEqual(ceiling, UIState.detailColumnWidthRange.upperBound,
                       "and on a display with this much room the ceiling is the "
                       + "writer's whole range")

        let landed = ProjectWindow.draggedDetailColumnWidth(
            startWidth: probe.width, translation: -400, containerWidth: measured)
        XCTAssertEqual(landed, UIState.detailColumnWidthRange.upperBound,
                       "so hauling the handle left reaches it — the branch's "
                       + "headline capability, which was unreachable on every "
                       + "display until this test existed")
    }

    /// **The narrow-window drag, which is the corner the re-review found open.**
    /// A writer on a laptop hauls the handle as far left as it will go. The
    /// column may not bank the range's 480 behind their back — a width they were
    /// never shown, which would reappear the next time they opened the project
    /// on a big display and look exactly like the app inventing a layout.
    func test_aDragOnANarrowWindowStopsAtWhatTheWindowAffords() {
        let affordable = ProjectWindow.effectiveDetailColumnWidth(
            persisted: UIState.detailColumnWidthRange.upperBound,
            containerWidth: 980)
        XCTAssertLessThan(affordable, UIState.detailColumnWidthRange.upperBound,
                          "premise: 980 cannot afford the whole range, or this "
                          + "test is about nothing")

        let landed = ProjectWindow.draggedDetailColumnWidth(
            startWidth: 280, translation: -400, containerWidth: 980)

        XCTAssertEqual(landed, affordable,
                       "a drag hauled past what the window can show must stop "
                       + "where the column stops moving")
    }

    /// And on a window with room, the same drag is held by the column's own
    /// range instead — otherwise the assertion above would pass against a
    /// function that simply always returned its narrowest answer.
    func test_theSameDragOnAWideWindowStopsAtTheColumnsOwnCeiling() {
        XCTAssertEqual(
            ProjectWindow.draggedDetailColumnWidth(
                startWidth: 280, translation: -400, containerWidth: 1600),
            UIState.detailColumnWidthRange.upperBound,
            "1600 affords the whole range, so the range is what stops it")
    }

    /// The other end, and the sign.
    func test_aDragRightNarrowsToTheFloorAndNoFurther() {
        XCTAssertEqual(
            ProjectWindow.draggedDetailColumnWidth(
                startWidth: 400, translation: 400, containerWidth: 1600),
            UIState.detailColumnWidthRange.lowerBound)
    }

    /// **The sign is a rule, not an implementation detail.** The handle is on
    /// the column's LEADING edge, so leftward — a negative translation — must
    /// widen it. Getting this backwards is a resize that fights the writer's
    /// hand, and until the extraction it was checkable only by reading the
    /// subtraction.
    func test_draggingLeftWidensAndDraggingRightNarrows() {
        let wider = ProjectWindow.draggedDetailColumnWidth(
            startWidth: 320, translation: -40, containerWidth: 1600)
        let narrower = ProjectWindow.draggedDetailColumnWidth(
            startWidth: 320, translation: 40, containerWidth: 1600)

        XCTAssertEqual(wider, 360)
        XCTAssertEqual(narrower, 280)
        XCTAssertGreaterThan(wider, narrower,
                             "leftward widens: the handle is on the leading edge")
    }

    /// An untouched gesture (no translation yet) must land exactly where it
    /// started, or the first frame of every drag is a jump.
    func test_aDragThatHasNotMovedYetChangesNothing() {
        XCTAssertEqual(
            ProjectWindow.draggedDetailColumnWidth(
                startWidth: 337, translation: 0, containerWidth: 1600),
            337)
    }

    // MARK: - The census: production asks for a width, from one place

    /// **What the harness above cannot see.** It measures AppKit, not Maugham —
    /// every assertion in this file would stay green if `ProjectWindow` went
    /// back to the range tomorrow. This is the line that ties the two together.
    func test_theRightColumnAsksForAWidthAndNotARange() throws {
        let code = try Self.codeLines(of: "Views/ProjectWindow.swift")

        XCTAssertEqual(
            code.filter {
                $0.contains("Self.effectiveDetailColumnWidth(persisted: detailColumnWidth,")
            }.count,
            1,
            "the detail column is pinned to one width, in exactly one place")
        XCTAssertTrue(
            code.allSatisfy { !$0.contains("navigationSplitViewColumnWidth(detailColumnWidth)") },
            "and it is the EFFECTIVE width, never the stored one handed over "
            + "raw: a stored width the window cannot afford does not squeeze a "
            + "column, it grows the window — which is this task's own complaint "
            + "moved to the window edge (see the narrow-window tests above)")
        XCTAssertTrue(
            code.allSatisfy { !$0.contains("navigationSplitViewColumnWidth(min: 240") },
            "and it must not go back to declaring a range — a range is what "
            + "moved under the writer on every mode change (see this file's "
            + "planted offender for the two ways it does)")

        // A fixed column's own divider is inert (measured: a programmatic
        // `setPosition` on it moves nothing), so the handle is the ONLY way the
        // width can be changed. Losing the call loses the capability in
        // silence — the column would simply never be resizable again.
        XCTAssertTrue(
            code.contains { $0.contains("detailResizeHandle(documentStore: documentStore)") },
            "the column must mount its own resize handle: the split view's "
            + "divider cannot move a fixed column, so without this the writer's "
            + "one width is one width forever")
    }

    /// **The rules above are only the writer's rules if the gesture calls
    /// them.** Extracting them made them testable and made a second copy
    /// possible in the same stroke: a `DragGesture` body is a closure nobody
    /// reads twice, and an inline `min(...)` there would satisfy every
    /// assertion in the section above while the shipped drag obeyed something
    /// else. So the census asks where the call is, not merely whether it exists
    /// — inside the resize gesture's `onChanged`, between the `DragGesture` that
    /// opens it and the `onEnded` that closes it.
    func test_theResizeGestureLandsThroughTheOneFunction() throws {
        let code = try Self.codeLines(of: "Views/ProjectWindow.swift")

        XCTAssertTrue(
            Self.resizeGestureOnChanged(calls: "Self.draggedDetailColumnWidth(",
                                        in: code),
            "the handle's drag must land through `draggedDetailColumnWidth` — "
            + "the sign, the range and the window's affordability are that "
            + "function's, and a gesture doing its own arithmetic is a second "
            + "set of rules with no test on it")
        XCTAssertEqual(
            code.filter { $0.contains("Self.draggedDetailColumnWidth(") }.count, 1,
            "and it is called once: a second drag site is a second place for "
            + "the ceiling to go missing")
    }

    /// **The planted offender.** The same predicate over a gesture that does its
    /// own clamping — the exact regression this census exists for — must come
    /// back false, and the control alongside it must still come back true, so
    /// the check is not simply answering "no" to everything.
    func test_theGestureCensusSeesADragThatClampsItself() {
        let offender = [
            "DragGesture(minimumDistance: 1)",
            "    .onChanged { value in",
            "        detailColumnWidth = UIState.clampedDetailColumnWidth(",
            "            start - value.translation.width)",
            "    }",
            "    .onEnded { _ in persist() }"
        ]
        XCTAssertFalse(
            Self.resizeGestureOnChanged(calls: "Self.draggedDetailColumnWidth(",
                                        in: offender),
            "a gesture clamping on its own must not read as compliant")

        let compliant = [
            "DragGesture(minimumDistance: 1)",
            "    .onChanged { value in",
            "        detailColumnWidth = Self.draggedDetailColumnWidth(",
            "            startWidth: start, translation: value.translation.width,",
            "            containerWidth: containerWidth)",
            "    }",
            "    .onEnded { _ in persist() }"
        ]
        XCTAssertTrue(
            Self.resizeGestureOnChanged(calls: "Self.draggedDetailColumnWidth(",
                                        in: compliant),
            "the control: the same scan says yes to the shape it is looking for")
    }

    /// And the case that would make the census unfalsifiable: a call that sits
    /// in the file but AFTER the gesture closes is not a call the drag makes.
    func test_theGestureCensusIgnoresACallOutsideTheGesture() {
        let outside = [
            "DragGesture(minimumDistance: 1)",
            "    .onChanged { value in detailColumnWidth = value.translation.width }",
            "    .onEnded { _ in persist() }",
            "let elsewhere = Self.draggedDetailColumnWidth("
        ]
        XCTAssertFalse(
            Self.resizeGestureOnChanged(calls: "Self.draggedDetailColumnWidth(",
                                        in: outside),
            "presence in the file is not the question — the question is whether "
            + "the drag goes through it")
    }

    /// One write site, so the value the writer dragged to is the value that is
    /// stored — the shape `memory/feedback_census_over_warning.md` asks for on
    /// anything a second author could plausibly add a second writer to.
    func test_theWidthIsWrittenFromExactlyOneProductionSite() throws {
        XCTAssertEqual(try Self.filesWritingTheWidth(),
                       ["ProjectWindow.swift"],
                       "only the column's own drag handle may persist this "
                       + "width; anything else is a second author of the "
                       + "writer's layout")
    }

    /// **The control**, without which the census could be scanning a tree with
    /// nothing in it and reporting a list somebody wrote down.
    func test_theWriteCensusSeesASecondWriter() throws {
        XCTAssertEqual(
            try Self.filesWritingTheWidth(
                plus: ["SomeNewModifier.swift":
                        "documentStore.updateUIState { $0.detailColumnWidth = 280 }"]),
            ["ProjectWindow.swift", "SomeNewModifier.swift"])
    }

    /// And the control on the control: prose quoting the write is not a write.
    func test_theWriteCensusDoesNotCountAComment() throws {
        XCTAssertEqual(
            try Self.filesWritingTheWidth(
                plus: ["CommentedOnly.swift":
                        "/// written as `$0.detailColumnWidth = width`, once."]),
            ["ProjectWindow.swift"])
    }

    // MARK: - Census helpers

    private static var appSourceDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MaughamTests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Maugham", isDirectory: true)
    }

    /// Whether `token` appears inside the resize gesture's `onChanged` body —
    /// i.e. between the `DragGesture` that opens the gesture and the `onEnded`
    /// that ends it. Takes the lines rather than the file so the planted
    /// offender above runs through this exact scan and not a second copy of it.
    ///
    /// Its honest limit: it is line containment, not parsing, so it would be
    /// fooled by a second `DragGesture` in this file appearing first. There is
    /// exactly one, and if a second arrives this predicate needs to say which —
    /// which is a better failure than a silent one.
    private static func resizeGestureOnChanged(calls token: String,
                                               in code: [String]) -> Bool {
        guard let opens = code.firstIndex(where: {
            $0.contains("DragGesture(minimumDistance: 1)")
        }) else { return false }
        guard let closes = code[opens...].firstIndex(where: {
            $0.contains(".onEnded")
        }) else { return false }
        return code[opens..<closes].contains { $0.contains(token) }
    }

    private static func codeLines(of relativePath: String) throws -> [String] {
        let url = appSourceDir.appendingPathComponent(relativePath)
        return SourceScan.codeLines(of: try String(contentsOf: url, encoding: .utf8))
    }

    /// `plus` runs synthetic sources through the identical predicate, so the
    /// two companions above test *this* scan rather than a second copy of it.
    private static func filesWritingTheWidth(
        plus injected: [String: String] = [:]
    ) throws -> [String] {
        var sources: [(name: String, text: String)] = []
        let fm = FileManager.default
        let walker = try XCTUnwrap(
            fm.enumerator(at: appSourceDir, includingPropertiesForKeys: nil))
        for case let url as URL in walker where url.pathExtension == "swift" {
            sources.append((url.lastPathComponent,
                            try String(contentsOf: url, encoding: .utf8)))
        }
        sources.append(contentsOf: injected.map { ($0.key, $0.value) }
            .sorted { $0.0 < $1.0 })

        return sources.filter { source in
            SourceScan.codeLines(of: source.text).contains {
                $0.contains("$0.detailColumnWidth =")
            }
        }.map(\.name)
    }

    // MARK: - Hosting

    private func width(of split: NSSplitView) -> CGFloat {
        split.arrangedSubviews.last?.frame.width ?? -1
    }

    /// Drives the split view's own divider, which is how the RANGE spelling is
    /// dragged. The production spelling has no draggable divider — its handle
    /// writes the value — so this is only ever used on the offender.
    @discardableResult
    private func dragDivider(of split: NSSplitView,
                             toDetailWidth target: CGFloat) async throws -> CGFloat {
        split.setPosition(split.frame.width - target,
                          ofDividerAt: split.arrangedSubviews.count - 2)
        await pump(0.6)
        return width(of: split)
    }

    private func mount(_ probe: DetailColumnProbe,
                       windowWidth: CGFloat = 1200) async throws -> (NSWindow, NSSplitView) {
        let frame = CGRect(x: 0, y: 0, width: windowWidth, height: 700)
        let hosting = NSHostingView(rootView: AnyView(DetailColumnHarness(probe: probe)))
        hosting.frame = frame
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        windows.append(window)
        await pump(1.0)

        var found: [NSSplitView] = []
        collect(NSSplitView.self, in: try XCTUnwrap(window.contentView), into: &found)
        let split = try XCTUnwrap(found.first,
                                  "the NavigationSplitView never reached the "
                                  + "hierarchy — nothing below measures anything")
        XCTAssertEqual(split.arrangedSubviews.count, 3,
                       "premise: three columns, the last of which is the one "
                       + "this file is about")
        return (window, split)
    }

    private func collect<T: NSView>(_ type: T.Type, in view: NSView, into out: inout [T]) {
        if let hit = view as? T { out.append(hit) }
        for sub in view.subviews { collect(type, in: sub, into: &out) }
    }

    private func pump(_ seconds: TimeInterval) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            settle(0.02)
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func settle(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
