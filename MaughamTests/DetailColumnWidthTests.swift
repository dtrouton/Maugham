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
///
/// **A mounted test cannot ask for a window; it can only ask a display for one**
/// (CI run 31339238337, 2026-08-09). Three tests here mounted "a wide window" by
/// requesting 1400pt and asserting against the 480pt range that width affords.
/// `NSWindow` clamps to the screen's visible frame, and GitHub's `macos-26`
/// runner — the SAME macOS and Xcode as the developer machine, which is what
/// CLAUDE.md's runner-parity rule is about — mounts a 1024pt display against
/// this Mac's 1470. So the runner's "wide" window was 1024pt, the affordability
/// sum quite correctly reduced a 480 wish to 336, and three tests went red for
/// being right. **Same OS is not the same DISPLAY.** Every mounted case here now
/// reads its premise off the window it actually got, the cases that genuinely
/// need a big display skip with a named reason, and
/// `test_theWideDisplayPremiseIsTheDisplaysAnswerAndNotAShrunkenMount` is the
/// control that goes red the day those skips start firing on a Mac that could
/// have run them.
@MainActor
final class DetailColumnWidthTests: XCTestCase {

    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        for window in windows { window.contentView = NSView(frame: .zero) }
        settle(0.05)
        windows.removeAll()
    }

    // MARK: - The display these mounted tests are standing on

    /// How wide a window has to be before the whole range is affordable at all —
    /// the three columns' floors plus the range's ceiling. Derived, because a
    /// worked number in prose is the unmaintainable-count defect wearing
    /// arithmetic (see `effectiveDetailColumnWidth`'s own comment on that).
    private static let windowWidthAffordingTheWholeRange =
        Double(ProjectWindow.binderColumnFloor + ProjectWindow.sidebarInset
               + ProjectWindow.centreColumnFloor)
        + UIState.detailColumnWidthRange.upperBound

    /// What the wide cases ASK a display for. What they GET is this or the
    /// display, whichever is smaller — which is the whole of the CI finding in
    /// this file's doc comment.
    private static let wideRequest: CGFloat = 1400

    /// The display these tests mount on, in points. `nil` only where there is no
    /// screen at all, in which case a window is not clamped by anything.
    private static var displayWidth: Double? {
        (NSScreen.main ?? NSScreen.screens.first)
            .map { Double($0.visibleFrame.width) }
    }

    /// The display's width, or "unbounded" where there is no display — the shape
    /// the premise arithmetic wants, since a missing screen clamps nothing.
    private static var displayWidthOrUnbounded: Double {
        displayWidth ?? .greatestFiniteMagnitude
    }

    /// **What THIS window affords the right column**, asked of production's own
    /// sum rather than restated here. Reads the probe's *measured* container
    /// rather than the window's frame, because the measured value is what the
    /// column is actually laid out from — and where nothing has been recorded,
    /// production's own nil fallback is the honest answer.
    private func afforded(_ probe: DetailColumnProbe) -> Double {
        ProjectWindow.draggableDetailCeiling(containerWidth: probe.containerWidth)
    }

    /// The width the column is SHOWN at for the writer's current wish in this
    /// window: their wish, reduced only as far as this display makes necessary.
    private func shown(_ probe: DetailColumnProbe) -> Double {
        ProjectWindow.effectiveDetailColumnWidth(
            persisted: probe.width, containerWidth: probe.containerWidth)
    }

    /// The named skip for a case whose premise is a big display. It names what
    /// the display gave, what the case needed, and — the part that keeps a skip
    /// from being a quiet deletion — which sibling holds the same protection on
    /// a display of any size.
    private func skipUnlessThisDisplayAffordsTheWholeRange(
        _ window: NSWindow, _ probe: DetailColumnProbe,
        heldOnAnyDisplayBy sibling: String
    ) throws {
        let room = afforded(probe)
        try XCTSkipUnless(
            room >= UIState.detailColumnWidthRange.upperBound,
            "this display mounted a \(window.frame.width)pt window, which "
            + "affords a \(room)pt right column; the whole "
            + "\(UIState.detailColumnWidthRange.upperBound)pt range needs "
            + "\(Self.windowWidthAffordingTheWholeRange)pt. GitHub's macos-26 "
            + "runner mounts a 1024pt display (run 31339238337) — same macOS as "
            + "this machine, different DISPLAY. The same protection runs on any "
            + "display in `\(sibling)`.")
    }

    /// The premise the *narrow*-window cases are made of, which is the same rule
    /// pointing the other way: they mount at the window's own declared floor to
    /// measure what a squeezed layout does, and a display that cannot even show
    /// that floor gives them a window neither they nor production is about.
    ///
    /// Asked of the DISPLAY rather than of the mounted window on purpose — the
    /// defect those cases guard is a window that silently GROWS past the floor,
    /// and a premise read off the window would skip exactly when it fired.
    private static func skipUnlessThisDisplayCanMountTheWindowFloor() throws {
        try XCTSkipUnless(
            displayWidthOrUnbounded >= Double(ProjectWindow.windowFloor),
            "this display is \(displayWidthOrUnbounded)pt wide, narrower than "
            + "the window's own \(ProjectWindow.windowFloor)pt floor, so a "
            + "window cannot be mounted at that floor to be measured")
    }

    /// **The mechanism behind this file's CI finding, reproduced on any Mac.**
    /// Ask for a window wider than the screen and AppKit hands back the screen —
    /// silently, with the test none the wiser unless it looks. That is the
    /// runner's condition arriving on the developer's own machine, and it is why
    /// "a wide window" is something a test reads off the window rather than a
    /// number it can ask for.
    func test_aWindowWiderThanTheDisplayIsClampedToIt() async throws {
        let display = try XCTUnwrap(
            Self.displayWidth,
            "no display at all: every mounted case in this file is measuring "
            + "something other than what it claims")
        let probe = DetailColumnProbe(width: UIState.defaultDetailColumnWidth)
        let (window, _) = try await mount(probe,
                                          windowWidth: CGFloat(display + 600))
        await pump(0.5)

        XCTAssertEqual(Double(window.frame.width), display, accuracy: 2,
                       "AppKit clamps a window to the display it opens on — a "
                       + "600pt-too-wide request came back as the screen")
        XCTAssertEqual(afforded(probe),
                       ProjectWindow.draggableDetailCeiling(
                        containerWidth: Double(window.frame.width)),
                       accuracy: 1,
                       "and what the writer can reach is what the CLAMPED "
                       + "window affords, never what was asked for — the whole "
                       + "of why three tests here were green on this Mac and "
                       + "red on CI run 31339238337. (Not the same as saying "
                       + "the memo holds the clamped number: it deliberately "
                       + "keeps the first measurement while the ceiling is "
                       + "unchanged, which on a display this wide it is.)")
    }

    /// **CI's own window, mounted here.** The three cases this file lost on the
    /// runner all read the same way on a developer machine — green, and about
    /// nothing — because 1470pt affords everything they asked about. This one
    /// asks for the runner's 1024 on purpose, so the squeeze CI puts the column
    /// under is a thing this suite measures rather than a thing it discovers
    /// once a push.
    ///
    /// It is the narrow-window sum's mounted twin: the arithmetic itself is
    /// covered by `test_theAffordabilitySumGivesTheWindowWhatItNeedsAndTheWriterTheRest`,
    /// and what this adds is that a real `NavigationSplitView` in a real window
    /// of that size lays the column out at the reduced width rather than growing
    /// the window to fit the wish.
    func test_aRunnerSizedWindowShowsTheColumnOnlyWhatItAffords() async throws {
        let runnerDisplay: CGFloat = 1024
        try XCTSkipUnless(
            Self.displayWidthOrUnbounded >= Double(runnerDisplay),
            "this display is \(Self.displayWidthOrUnbounded)pt wide and cannot "
            + "mount CI's own \(runnerDisplay)pt window to be measured")

        let probe = DetailColumnProbe(
            width: UIState.detailColumnWidthRange.upperBound)
        let (window, split) = try await mount(probe, windowWidth: runnerDisplay)
        await pump(0.8)

        XCTAssertEqual(window.frame.width, runnerDisplay, accuracy: 1,
                       "premise: the window opened at the runner's width — and "
                       + "did not GROW to fit a wish it cannot afford, which is "
                       + "this task's own complaint moved to the window edge")

        // Off the window rather than off the number asked for, and for the same
        // reason as everything else in this section: AppKit answers a 1024pt
        // request with 1025 often enough (CI's own log does, twice) that a
        // literal here would be riding a 1pt accuracy margin.
        let expected = ProjectWindow.effectiveDetailColumnWidth(
            persisted: UIState.detailColumnWidthRange.upperBound,
            containerWidth: Double(window.frame.width))
        XCTAssertLessThan(expected, UIState.detailColumnWidthRange.upperBound,
                          "premise: \(runnerDisplay)pt cannot afford the whole "
                          + "range, or this test is about nothing")
        XCTAssertEqual(width(of: split), expected, accuracy: 1,
                       "the column is given \(expected)pt — what is left after "
                       + "the binder and the prose take their floors")
        XCTAssertEqual(probe.width, UIState.detailColumnWidthRange.upperBound,
                       "and the writer's wish is untouched: they get their 480 "
                       + "back on the display they set it on")
        XCTAssertEqual(probe.widthWrites, 0, "nothing wrote it, either")
    }

    /// **The control on every skip in this file.** A premise that skips is only
    /// honest while it skips for the reason it names; the failure this guards is
    /// a harness that quietly mounts something smaller than the display allows,
    /// under which the wide cases would skip on Denver's own Mac and a suite
    /// that skips everywhere protects nothing.
    ///
    /// It never skips itself: both halves are true statements on a small display
    /// as much as a large one.
    func test_theWideDisplayPremiseIsTheDisplaysAnswerAndNotAShrunkenMount() async throws {
        XCTAssertGreaterThanOrEqual(
            Double(Self.wideRequest), Self.windowWidthAffordingTheWholeRange,
            "premise: the wide cases ask for a window that would afford the "
            + "whole range wherever the display allows it — otherwise they skip "
            + "for a reason of their own making")

        let probe = DetailColumnProbe(width: UIState.defaultDetailColumnWidth)
        let (window, _) = try await mount(probe, windowWidth: Self.wideRequest)
        await pump(0.5)

        XCTAssertEqual(Double(window.frame.width),
                       min(Double(Self.wideRequest), Self.displayWidthOrUnbounded),
                       accuracy: 2,
                       "the mount must be as wide as this display allows: every "
                       + "skip here is keyed on what a mounted window comes back "
                       + "at, so a harness mounting something smaller turns them "
                       + "all into quiet deletions")
        XCTAssertEqual(
            afforded(probe) >= UIState.detailColumnWidthRange.upperBound,
            Self.displayWidthOrUnbounded >= Self.windowWidthAffordingTheWholeRange,
            "and the wide cases run exactly when the DISPLAY can afford them — "
            + "this is the assertion that goes red the day they are skipped on a "
            + "machine that could have run them")
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
        // What the writer is SHOWN, captured once: on a display too narrow for
        // their 320 this is less, and the claim — that a mode change does not
        // move it — is the same claim about the same column either way. The
        // literal that used to stand here made the test's subject the display.
        let held = shown(probe)
        XCTAssertEqual(width(of: split), held, accuracy: 1,
                       "premise: the column opens at the writer's own width, "
                       + "reduced only by what this display affords")

        for pane in [1, 2, 0] {
            probe.pane = pane
            probe.mounted = false
            await pump(0.5)
            probe.mounted = true
            probe.visibility = .doubleColumn
            await pump(0.5)
            probe.visibility = .all
            await pump(0.6)

            XCTAssertEqual(width(of: split), held, accuracy: 1,
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
        let held = shown(probe)

        probe.pane = 1
        await pump(0.7)
        XCTAssertEqual(width(of: split), held, accuracy: 1,
                       "a pane whose content wants to be wider than the column "
                       + "must be given the column's width, not the other way "
                       + "round")

        probe.pane = 0
        await pump(0.7)
        XCTAssertEqual(width(of: split), held, accuracy: 1)
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
        let held = shown(probe)

        probe.pane = 1
        await pump(0.8)
        XCTAssertEqual(width(of: split), held, accuracy: 1,
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
        let held = shown(probe)
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
        XCTAssertEqual(width(of: split), held, accuracy: 1)

        // The control: the gesture's own write does reach it, so a probe that
        // simply cannot count is not what the zero above is made of. The width
        // it moves to is the widest this display can show — a literal 360 here
        // was one of the three cases CI's 1024pt screen could not afford, and
        // what the control needs is a width DIFFERENT from the one held above,
        // not a particular number.
        let target = min(360, afforded(probe))
        try XCTSkipUnless(
            target > held + 8,
            "this display shows the column at \(held)pt and affords at most "
            + "\(afforded(probe))pt, so there is no second width to move to and "
            + "'follows the value live' cannot be told from 'did not move'. The "
            + "zero-write assertions above have already run and hold.")

        probe.width = target
        await pump(0.6)
        XCTAssertEqual(probe.widthWrites, 1)
        XCTAssertEqual(width(of: split), target, accuracy: 1,
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
    /// ways in clamp.
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
        try Self.skipUnlessThisDisplayCanMountTheWindowFloor()
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
        try Self.skipUnlessThisDisplayCanMountTheWindowFloor()
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

    /// The other side of the asymmetry: a window that can afford the wish gives
    /// the wish, whole. Without this, a clamp that simply always returned its
    /// floor — or one that always returned what the window affords — would
    /// satisfy every assertion above.
    ///
    /// **The wish is the DEFAULT rather than the range's ceiling, and that is
    /// what lets this run on any display.** The claim is about the asymmetry,
    /// not about 480: what it needs is a wish this window has room for, sitting
    /// clear of both the range's floor (so honouring it differs from clamping to
    /// it) and what the window affords (so honouring it differs from reducing to
    /// it). The default is such a wish on every Mac display, including the
    /// 1024pt one CI mounts. `test_aWideDisplayGivesTheWholeRangeAndLetsADragReachIt`
    /// makes the same claim at the range's ceiling where a display allows it.
    ///
    /// **The premise is read off the window rather than off what was asked
    /// for.** A requested 1600 came back as 1470 on this machine — `NSWindow`
    /// will not open wider than the screen — which is exactly the class of
    /// silently-different-window this whole fix round is about, arriving from
    /// the other direction.
    func test_aWindowWithRoomHonoursTheWholeWish() async throws {
        let wish = UIState.defaultDetailColumnWidth
        let probe = DetailColumnProbe(width: wish)
        let (window, split) = try await mount(probe, windowWidth: Self.wideRequest)
        await pump(0.8)

        let room = afforded(probe)
        try XCTSkipUnless(
            room > wish,
            "this display mounted a \(window.frame.width)pt window, which "
            + "affords \(room)pt — not more than the \(wish)pt wish, so "
            + "'honoured whole' cannot be told apart from 'reduced to what the "
            + "window affords'. No Mac display is this narrow.")
        XCTAssertGreaterThan(
            wish, UIState.detailColumnWidthRange.lowerBound,
            "premise: the wish is clear of the range's floor, so honouring it "
            + "is distinguishable from clamping to it")

        XCTAssertEqual(width(of: split), wish, accuracy: 1,
                       "a window with the room gives the writer their whole "
                       + "wish — neither reduced to the \(room)pt this window "
                       + "affords nor dropped on the range's floor; the "
                       + "reduction is affordability, not policy")
    }

    /// **The headline capability at its full size, where a display allows it.**
    /// The two claims that genuinely need a big screen, kept together because
    /// they share one premise: on a display with room for the whole range, the
    /// column is given all 480 of it and a drag can reach all 480 of it.
    ///
    /// This is the wide half of what
    /// `test_aWindowWithRoomHonoursTheWholeWish` and
    /// `test_aFreshProjectCanDragPastTheUnmeasuredFallback` hold on any display.
    /// It skips, loudly and by name, where the display cannot afford it — CI's
    /// runner cannot; Denver's Mac can, and
    /// `test_theWideDisplayPremiseIsTheDisplaysAnswerAndNotAShrunkenMount` is
    /// what keeps that true.
    func test_aWideDisplayGivesTheWholeRangeAndLetsADragReachIt() async throws {
        let probe = DetailColumnProbe(
            width: UIState.detailColumnWidthRange.upperBound)
        let (window, split) = try await mount(probe, windowWidth: Self.wideRequest)
        await pump(0.8)
        try skipUnlessThisDisplayAffordsTheWholeRange(
            window, probe,
            heldOnAnyDisplayBy: "test_aWindowWithRoomHonoursTheWholeWish and "
            + "test_aFreshProjectCanDragPastTheUnmeasuredFallback")

        XCTAssertEqual(width(of: split),
                       UIState.detailColumnWidthRange.upperBound, accuracy: 1,
                       "a display with room for the whole range gives the "
                       + "writer the whole range")
        XCTAssertEqual(
            ProjectWindow.draggedDetailColumnWidth(
                startWidth: UIState.defaultDetailColumnWidth,
                translation: -400,
                containerWidth: probe.containerWidth),
            UIState.detailColumnWidthRange.upperBound,
            "and a drag from the default reaches it — the branch's headline "
            + "capability at the size the writer asked for")
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
    ///
    /// **What the starved memo cost was never the number 480** — it was that the
    /// drag ceiling stayed the *unmeasured fallback* however much room the
    /// writer's display had. So that is what this asserts, and it needs nothing
    /// more than a window wider than the floor: the memo must record, the
    /// ceiling must exceed the fallback, and a haul left must reach that ceiling
    /// rather than stop short of it. Asserting the ceiling was 480 made the test
    /// a claim about the developer's monitor, and CI's 1024pt display duly
    /// failed it (run 31339238337) while the defect it guards was nowhere in
    /// sight. `test_aWideDisplayGivesTheWholeRangeAndLetsADragReachIt` keeps the
    /// 480 where a display can afford it.
    func test_aFreshProjectCanDragPastTheUnmeasuredFallback() async throws {
        let probe = DetailColumnProbe(width: UIState.defaultDetailColumnWidth)
        let (window, _) = try await mount(probe, windowWidth: Self.wideRequest)
        await pump(0.8)

        let unmeasured = ProjectWindow.draggableDetailCeiling(containerWidth: nil)
        try XCTSkipUnless(
            Double(window.frame.width) > Double(ProjectWindow.windowFloor),
            "this display mounted a \(window.frame.width)pt window, no wider "
            + "than the \(ProjectWindow.windowFloor)pt floor the unmeasured "
            + "fallback already assumes, so there is no 'past the fallback' "
            + "here to reach. No Mac display is this narrow.")

        let measured = try XCTUnwrap(
            probe.containerWidth,
            "the guard must have recorded a window this much wider than the "
            + "floor — a nil here is the starved memo itself")
        XCTAssertEqual(measured, Double(window.frame.width), accuracy: 1,
                       "and what it recorded is the window the writer is "
                       + "actually in, not the width this test asked for")

        let ceiling = ProjectWindow.draggableDetailCeiling(containerWidth: measured)
        XCTAssertGreaterThan(ceiling, unmeasured,
                             "a measured wide window must afford more than the "
                             + "unmeasured fallback of \(unmeasured)pt")

        let landed = ProjectWindow.draggedDetailColumnWidth(
            startWidth: probe.width, translation: -400, containerWidth: measured)
        XCTAssertEqual(landed, ceiling,
                       "so hauling the handle left reaches everything this "
                       + "display has — the branch's headline capability, which "
                       + "was unreachable on every display until this test "
                       + "existed")
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
