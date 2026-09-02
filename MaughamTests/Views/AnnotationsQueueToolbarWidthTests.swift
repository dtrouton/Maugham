import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **The queue has to fit the column it is drawn in.**
///
/// Denver's smoke, 2026-08-15: in Review with notes in the right column, the
/// pane's content was clipped at the LEFT edge — annotation bodies starting
/// mid-sentence, the toolbar cut at both ends, and a suggestion's diff card
/// running past the right edge barely wrapping.
///
/// **One cause, three symptoms.** The toolbar was `HStack(spacing: 0)` over the
/// kind filter and six controls, every one of them `.fixedSize()`. A row of
/// incompressible children has a MINIMUM width equal to their sum, so the row
/// could not be squeezed into the column; the pane's layout width inflated to
/// hold it, SwiftUI centred that overflow, and everything below — including the
/// diff card, whose own `Text`s were correctly compressible all along — was laid
/// out against the inflated width rather than the column's. The card "not
/// wrapping" was never the card's bug.
///
/// **The instrument is a proposal, not a frame walk.** The obvious measurement —
/// mount at 280pt and look for a descendant `NSView` escaping the hosting view's
/// bounds — reads zero here, always: `NSHostingView` positions and clips its
/// backing views inside its own bounds however wide the SwiftUI content laid
/// itself out. Measured 2026-08-15 against a deliberately incompressible row
/// (six `.fixedSize()` worded menus): the frame walk reported no escape at 240pt
/// or 280pt while the content was 1226pt wide. What DOES see it is asking
/// SwiftUI directly — `NSHostingController.sizeThatFits(in:)` offers the content
/// a width and returns the width it actually takes. The same probe returned 1226
/// for the incompressible row against a 240pt proposal and 220 for a
/// compressible one, which is the difference this suite is made of.
///
/// So: **overflow is `measured.width > proposed.width`**, and it is the same
/// question the writer's eye asks.
@MainActor
final class AnnotationsQueueToolbarWidthTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        // Every measurement here resolves fonts through production typography
        // (`.caption` labels, monospaced diff text) — the fontd cold-start
        // window, CLAUDE.md.
        FontWarmup.ensure()
    }

    // MARK: - The column these measurements are about

    /// The widths the right column actually takes, asked of production rather
    /// than written down. `lowerBound` is the floor a writer can drag to and the
    /// width every one of these controls has to survive; `default` is what an
    /// untouched project opens at and what Denver's screenshot was taken in.
    private static var columnWidths: [CGFloat] {
        [CGFloat(UIState.detailColumnWidthRange.lowerBound),
         CGFloat(UIState.defaultDetailColumnWidth)]
    }

    /// Sub-pixel slack. SwiftUI rounds label widths to the backing scale, and a
    /// row that lands a third of a point over its proposal is not what clipped
    /// Denver's sentences.
    private static let slack: CGFloat = 0.5

    // MARK: - The subject

    /// **The toolbar's hardest honest case.** Every optional control present, and
    /// the two labels a writer can make arbitrarily long — a pass's name and a
    /// collaborator's — carrying real values rather than the placeholder words.
    ///
    /// `scopeIsProject` is true because "All Pieces" is the wider of that menu's
    /// two labels; the pass is the longest preset unless a longer one is asked
    /// for. Nothing here is hypothetical: a project names its own passes and a
    /// shared project names its own people.
    ///
    /// **`authorFilter` is a parameter and not a constant, and that is the
    /// point of it.** The author menu's label is `authorFilter`, not
    /// `authorLabels` — the labels only populate the menu's items, which have no
    /// bearing on the row's width. A version of this factory that pinned the
    /// filter to `.all` made `test_aLongCollaboratorNameDoesNotWidenTheToolbar`
    /// a test of the word "Author" (six characters, no ceiling in sight): it
    /// stayed green with `authorNameCeiling` deleted. Found in review of
    /// `ba9346f3`. A long name has to be SELECTED to be measured.
    private func toolbar(
        passName: String = "Structural",
        authors: [String] = ["Denver", "Claude"],
        authorFilter: String = AnnotationAuthorFilter.all,
        bulk: Bool = true
    ) -> some View {
        let pass = ReviewPass(id: "p1", name: passName)
        return AnnotationsQueueToolbar(
            kindFilter: .constant(.all),
            passSelection: .constant(.pass(pass.id)),
            triageFilter: .constant(.all),
            authorFilter: .constant(authorFilter),
            showResolved: .constant(false),
            reviewPasses: [pass] + ReviewPass.presets,
            resolvedPassId: pass.id,
            scopeIsProject: true,
            showsBulkAffordances: bulk,
            selectionModeOn: false,
            authorLabels: authors,
            onSetScope: { _ in },
            onToggleSelectionMode: {})
    }

    /// **The headline claim.** At the column's floor and at its default, the
    /// toolbar takes the width it is offered and no more.
    ///
    /// Measured before the fix: 560.0pt at both — 320pt over the floor and 280pt
    /// over the default, a row asking for exactly twice the column it is in.
    func test_theToolbarFitsTheColumnItIsDrawnIn() {
        for width in Self.columnWidths {
            let measured = Self.width(of: toolbar(), proposing: width)
            XCTAssertLessThanOrEqual(
                measured, width + Self.slack,
                "the queue's toolbar wants \(measured)pt in a \(width)pt "
                + "column — \(measured - width)pt of overflow. A toolbar that "
                + "cannot compress inflates the whole pane's layout width, and "
                + "SwiftUI centres what overflows: that is the left-edge "
                + "clipping in Denver's smoke, and the diff card wrapping at "
                + "the wrong width underneath it.")
        }
    }

    /// **And the variant being measured above is the LAST one.**
    ///
    /// This is the assertion the claim actually rests on. `ViewThatFits` picks
    /// the first child that fits and draws the final child regardless — so a
    /// suite that only ever saw an earlier variant chosen would go green while
    /// the fallback was as unfittable as the shipped row. The stacked variant is
    /// two lines where the others are one, so its own height is the evidence
    /// that it is what a narrow column gets.
    func test_aNarrowColumnGetsTheStackedFallbackAndNotAWiderVariant() {
        let roomy = Self.size(of: toolbar(), proposing: 900)
        for width in Self.columnWidths {
            let squeezed = Self.size(of: toolbar(), proposing: width)
            XCTAssertGreaterThan(
                squeezed.height, roomy.height + 4,
                "at \(width)pt the toolbar must have fallen through to the "
                + "stacked variant (\(squeezed.height)pt tall against "
                + "\(roomy.height)pt at 900pt). If these are the same height, "
                + "a one-line variant is fitting after all and the fallback "
                + "this suite claims to have measured has never been drawn.")
        }
        XCTAssertLessThanOrEqual(
            roomy.width, 900,
            "premise: the roomy measurement is a real layout and not an "
            + "overflow of its own")
    }

    /// **A pass name is the writer's own string.** Nothing stops them calling one
    /// *Second pass — continuity and the timeline*, and a label with no ceiling
    /// is the whole toolbar's width budget handed to one control.
    func test_aWriterNamedPassDoesNotWidenTheToolbar() {
        let long = "Second pass \u{2014} continuity, timeline and the dog"
        for width in Self.columnWidths {
            let measured = Self.width(
                of: toolbar(passName: long), proposing: width)
            XCTAssertLessThanOrEqual(
                measured, width + Self.slack,
                "a \(long.count)-character pass name took the toolbar to "
                + "\(measured)pt in a \(width)pt column. The name has to "
                + "truncate or move into the tooltip — it cannot be allowed to "
                + "set the row's minimum width.")
        }
    }

    /// The same, for the other unbounded label: a collaborator's display name.
    /// The same, for the other unbounded label: a collaborator's display name,
    /// which reaches the toolbar as whatever a person typed into their own
    /// preferences on some other machine.
    ///
    /// **The name is SELECTED, not merely present in the menu.** `authorMenu`
    /// draws `authorFilter`; a long name sitting in `authorLabels` while the
    /// filter reads `.all` renders the six-character word "Author" and measures
    /// nothing at all — which is what the first version of this test did.
    func test_aLongCollaboratorNameDoesNotWidenTheToolbar() {
        let long = "A Reader With A Very Long Display Name Indeed"
        for width in Self.columnWidths {
            let measured = Self.width(
                of: toolbar(authors: ["Denver", long], authorFilter: long),
                proposing: width)
            XCTAssertLessThanOrEqual(
                measured, width + Self.slack,
                "with \"\(long)\" selected the toolbar wants \(measured)pt in a "
                + "\(width)pt column. A collaborator's display name is their "
                + "own string and cannot be allowed to set the row's width — it "
                + "truncates to `authorNameCeiling` when worded and moves into "
                + "the tooltip when compact.")
        }
    }

    /// **The assertion the two tests above only sample: nothing a writer can
    /// type is on the toolbar's critical path at all.**
    ///
    /// A fit assertion at 240pt and 280pt is satisfied by the stacked fallback
    /// whatever the labels do, which is how the first version of this suite
    /// stayed green over a broken ceiling. This measures the toolbar's own IDEAL
    /// width — `intrinsicContentSize`, what the content asks for before any
    /// column squeezes it — and requires that a writer's pass name and a
    /// collaborator's display name move it by exactly nothing.
    ///
    /// Measured while this was being fixed: with the labels worded, a 45-char
    /// display name took the ideal from 668pt to **939pt** and a 46-char pass
    /// name to **912pt**, ceilings notwithstanding — `.frame(maxWidth:)` bounds
    /// what a `Text` is proposed, not the ideal it reports, and `.fixedSize()`
    /// then forces the label to that unbounded ideal. Restore a worded label and
    /// this goes red; every other test in this file stays green, which is
    /// exactly why it has to exist.
    func test_nothingAWriterCanTypeChangesWhatTheToolbarAsksFor() {
        let baseline = Self.idealWidth(of: toolbar(
            passName: "P", authors: ["Denver", "Ann"], authorFilter: "Ann"))

        let longAuthor = "A Reader With A Very Long Display Name Indeed"
        let cases: [(String, CGFloat)] = [
            ("a 46-character pass name",
             Self.idealWidth(of: toolbar(
                passName: "Second pass \u{2014} continuity, timeline and the dog",
                authors: ["Denver", "Ann"], authorFilter: "Ann"))),
            ("a 45-character collaborator name",
             Self.idealWidth(of: toolbar(
                passName: "P", authors: ["Denver", longAuthor],
                authorFilter: longAuthor))),
        ]
        for (what, measured) in cases {
            XCTAssertEqual(
                measured, baseline, accuracy: Self.slack,
                "\(what) moved the toolbar's ideal width from \(baseline)pt to "
                + "\(measured)pt. A label carrying a string the writer owns is "
                + "a width budget handed to whoever names a pass — the words "
                + "belong in the tooltip and the menu, which have no width.")
        }
    }

    // MARK: - No variant may be unreachable

    /// **The test that would have caught the defect this suite shipped with.**
    ///
    /// The first fix offered three variants and the widest — a worded cluster —
    /// needed 668pt at its narrowest. The right column is capped at 480pt by
    /// `UIState.detailColumnWidthRange`, so nothing could ever draw it: it was
    /// dead on arrival, and the two label ceilings living inside it were dead
    /// with it. Every assertion in this file passed anyway, because a variant
    /// nobody reaches breaks nothing.
    ///
    /// A `ViewThatFits` is a ladder, and a rung above the top of the wall is not
    /// a rung. So: the toolbar's widest variant must be drawable somewhere
    /// inside the range the writer can actually drag to.
    func test_everyVariantIsReachableInsideTheColumnsOwnRange() {
        let ceiling = CGFloat(UIState.detailColumnWidthRange.upperBound)
        let ideal = Self.idealWidth(of: toolbar())
        XCTAssertLessThanOrEqual(
            ideal, ceiling,
            "the toolbar's widest variant wants \(ideal)pt and the right column "
            + "stops at \(ceiling)pt, so it can never be drawn — it is dead "
            + "code, and anything it alone contains is untested by every fit "
            + "assertion in this file. Either make it fit or delete it.")

        // The other end: the widest variant must actually be REACHED at the
        // column's ceiling, not merely fit in theory — otherwise a toolbar that
        // stacked at every width would satisfy the line above.
        let atCeiling = Self.size(of: toolbar(), proposing: ceiling)
        let stacked = Self.size(
            of: toolbar(),
            proposing: CGFloat(UIState.detailColumnWidthRange.lowerBound))
        XCTAssertLessThan(
            atCeiling.height, stacked.height,
            "at the widest column the writer can drag to the toolbar must be "
            + "on one line (\(atCeiling.height)pt) rather than still stacked "
            + "(\(stacked.height)pt) — a fallback that is the only thing ever "
            + "drawn means the variant above it is unreachable too")
    }

    // MARK: - The row underneath it

    /// **The row's verbs, at the same two widths.** `actionRow` is a
    /// `ViewThatFits` over a worded and an icon variant, and `ViewThatFits`
    /// renders its LAST child at whatever width it is given — fitting or not. So
    /// "there is a fallback" is not the same claim as "the fallback fits", and
    /// this is the one that is measured.
    ///
    /// The hardest row is the writer's own open suggestion: Accept, Reject,
    /// Stet, Archive, the triage menu, and the Edit + Delete pair `isOwn` adds —
    /// seven controls.
    ///
    /// Measured before the fix: 245.0pt at the 240pt floor and 280.58pt at the
    /// 280pt default. Small overflows, and exactly as bad as large ones — the
    /// pane's layout width inflates either way, and the column's contents are
    /// then centred against a width the column has not got.
    func test_theRowsVerbsFitTheColumn() {
        let row = AnnotationRow(
            annotation: Self.suggestion,
            isOwn: true,
            onAccept: {}, onReject: {}, onArchive: {}, onReply: {},
            onJumpToParagraph: {})
        for width in Self.columnWidths {
            let measured = Self.width(of: row, proposing: width)
            XCTAssertLessThanOrEqual(
                measured, width + Self.slack,
                "an own open suggestion's row wants \(measured)pt in a "
                + "\(width)pt column. Seven verbs on one line is the case "
                + "`actionRow`'s icon fallback exists for; if this is red the "
                + "fallback is not narrow enough to BE one.")
        }
    }

    /// **The fallback needs headroom, not a photo finish.** The version this
    /// task replaced missed the 280pt column by 0.58pt — a margin that a font
    /// substitution, a control-metrics change on the next macOS, or one more
    /// verb erases with nobody touching this code. "It fits" is therefore not
    /// the whole claim; "it fits with room" is.
    ///
    /// So this measures the row's own FLOOR — what it comes back with when
    /// offered nothing at all, which is the width its last variant cannot go
    /// below — and asks that the floor sit clear of the narrowest column a
    /// writer can drag to. Measured 2026-08-15: a floor of ~210pt against a
    /// 240pt column.
    func test_theVerbFallbackHasRoomToSpareBelowTheColumnFloor() {
        let columnFloor = CGFloat(UIState.detailColumnWidthRange.lowerBound)
        let row = AnnotationRow(
            annotation: Self.suggestion,
            isOwn: true,
            onAccept: {}, onReject: {}, onArchive: {}, onReply: {},
            onJumpToParagraph: {})
        let rowFloor = Self.width(of: row, proposing: 1)
        XCTAssertLessThanOrEqual(
            rowFloor + Self.headroom, columnFloor,
            "the verb row cannot be drawn narrower than \(rowFloor)pt, which "
            + "leaves \(columnFloor - rowFloor)pt of slack in the narrowest "
            + "column a writer can drag to. That is under the \(Self.headroom)pt "
            + "this suite asks for, so the next verb — or the next macOS's "
            + "button metrics — puts the queue back into overflow.")
    }

    /// The same claim for the toolbar: its stacked fallback must clear the
    /// column floor with room, not land on it.
    func test_theToolbarFallbackHasRoomToSpareBelowTheColumnFloor() {
        let columnFloor = CGFloat(UIState.detailColumnWidthRange.lowerBound)
        let barFloor = Self.width(of: toolbar(), proposing: 1)
        XCTAssertLessThanOrEqual(
            barFloor + Self.headroom, columnFloor,
            "the toolbar's stacked fallback cannot be drawn narrower than "
            + "\(barFloor)pt against a \(columnFloor)pt column — "
            + "\(columnFloor - barFloor)pt of slack, under the "
            + "\(Self.headroom)pt this suite asks for. An eighth control would "
            + "want a third line rather than a wider pane.")
    }

    /// How much slack a fallback has to keep below the narrowest column. Enough
    /// that one more control, or a different font, does not silently reopen the
    /// defect; small enough that it is a margin rather than a redesign.
    private static let headroom: CGFloat = 16

    // MARK: - The strip above it (M4 P2 Task 3)

    /// **The round cockpit at the column's floor** — the third thing in this
    /// pane whose width is not the pane's to give.
    ///
    /// It is measured HERE rather than in `ReviewRoundCockpitTests` because
    /// the instrument is here: `sizeThatFits` against a proposal, plus the
    /// `headroom` rule the two fallbacks already answer to. A width claim
    /// written beside the strip would be a second instrument for the one
    /// question this suite exists to ask.
    ///
    /// **The hardest honest case is a writer's own long pass name.** The
    /// preset ladder's names are short and its editors are one word; nothing
    /// bounds what a writer types into `ReviewPass.name`, and the lane line
    /// draws it. The buttons underneath are the incompressible part — the lane
    /// `Text` wraps to two lines and then truncates, which is a legible
    /// degrade rather than an overflow.
    func test_theRoundCockpitFitsTheColumn() {
        for width in Self.columnWidths {
            let measured = Self.width(of: Self.cockpit(), proposing: width)
            XCTAssertLessThanOrEqual(
                measured, width + Self.slack,
                "the round cockpit wants \(measured)pt in a \(width)pt column. "
                + "Its lane line wraps and truncates; if this is red something "
                + "in the strip is incompressible \u{2014} and the pane's layout "
                + "width inflates around it exactly as it did for the toolbar.")
        }
    }

    /// And the same headroom rule the two fallbacks answer to: the strip's own
    /// floor — what it comes back with offered nothing at all, which is what
    /// its buttons cannot be drawn narrower than — must sit clear of the
    /// narrowest column a writer can drag to.
    ///
    /// A third button, or the next macOS's control metrics, is what this is
    /// watching for. Measured 2026-08-17 with the long-named pass below: a
    /// floor of 56pt against a 240pt column, 184pt of slack — the strip's
    /// controls are `.controlSize(.small)` bordered buttons whose labels
    /// truncate, and its one `Text` wraps. The margin is generous because the
    /// strip is two short rows; what makes the number worth pinning is that an
    /// incompressible control added to it takes the margin all at once
    /// (falsified 2026-08-17 by planting a `.fixedSize()` worded button on the
    /// run row: both cockpit measurements went red, the fit one at every
    /// column width).
    func test_theRoundCockpitHasRoomToSpareBelowTheColumnFloor() {
        let columnFloor = CGFloat(UIState.detailColumnWidthRange.lowerBound)
        let stripFloor = Self.width(of: Self.cockpit(), proposing: 1)
        XCTAssertLessThanOrEqual(
            stripFloor + Self.headroom, columnFloor,
            "the cockpit cannot be drawn narrower than \(stripFloor)pt, which "
            + "leaves \(columnFloor - stripFloor)pt in the narrowest column a "
            + "writer can drag to \u{2014} under the \(Self.headroom)pt this "
            + "suite asks for. A third button on that row wants a wider pane "
            + "rather than a second line.")
    }

    /// The strip's hardest honest case: a pass the writer named at length,
    /// with an editor name of its own so the lane line draws BOTH (a pass
    /// whose editor falls back to its name collapses to one, which is
    /// narrower), a two-digit round, and the longest of the two status lines.
    private static func cockpit() -> some View {
        let pass = ReviewPass(
            id: "structural",
            name: "Late structural read before the Melbourne submission",
            brief: "b",
            editorName: "Perkins")
        return ReviewRoundCockpit(
            passes: [pass],
            activePassId: pass.id,
            round: 12,
            coach: nil,
            phase: .idle,
            reportLine: "Since round 11: 14 resolved \u{00b7} 9 persisting "
                + "\u{00b7} 21 new",
            onRun: { _ in },
            onSetActivePass: { _ in },
            onCancel: {})
    }

    /// **The picker + running arms — unmeasured until this fixture** (M4 P2
    /// Task 8 whole-branch review, Minor). `cockpit()` above fixes the lane
    /// line and the report line; a piece with no active pass draws
    /// `lanePicker`'s invitation label instead of the lane, and a run in flight draws
    /// `RoundNarrative.checkingCopy` instead of `reportLine` — different
    /// views entirely, and neither one's width was in this suite before a
    /// future control added to either would have escaped it silently.
    /// Worst-case delta text: both `new` and `revised` nonzero reaches
    /// `paragraphPhrase`'s longest branch, "N new and M revised paragraphs".
    ///
    /// **The running arm also draws Cancel now** (the cockpit-cancel
    /// follow-up) — a third `.bordered` control on the run row, and exactly
    /// the case `test_theRoundCockpitHasRoomToSpareBelowTheColumnFloor`'s own
    /// history warns about: "an incompressible control added to it takes the
    /// margin all at once." This fixture is what makes that button's own
    /// margin measured rather than assumed.
    private static func cockpitNoPassRunning() -> some View {
        ReviewRoundCockpit(
            passes: [ReviewPass(id: "structural", name: "Structural")],
            activePassId: nil,
            round: nil,
            coach: nil,
            phase: .running(CompilerOrchestrator.DeltaCounts(new: 999, revised: 999)),
            reportLine: nil,
            onRun: { _ in },
            onSetActivePass: { _ in },
            onCancel: {})
    }

    func test_theRoundCockpitFitsTheColumnWithNoPassAndARunInFlight() {
        for width in Self.columnWidths {
            let measured = Self.width(of: Self.cockpitNoPassRunning(), proposing: width)
            XCTAssertLessThanOrEqual(
                measured, width + Self.slack,
                "the round cockpit's picker+running arm wants \(measured)pt "
                + "in a \(width)pt column \u{2014} `cockpit()`'s lane+report "
                + "fixture never exercises the picker or the checking-copy "
                + "status line, so a control added to either escapes it.")
        }
    }

    /// **The failed arm — the strip's third status line, and its longest**
    /// (2026-08-18). `RunPhase` gained `.failed` so a round that dies says so
    /// where it was launched, and `RoundNarrative.failureCopy`'s longest
    /// sentence is `cliNotFound`'s two clauses with a Settings path in them —
    /// materially longer than either the lane line or the checking copy the two
    /// fixtures above measure, and the very sentence that
    /// `DiagnosticsPaneColumnHeightTests` records coming back ~400pt tall in the
    /// other pane when it was made unbreakable. A `.fixedSize(horizontal:)` or a
    /// `.lineLimit(1)` reached for to keep the red line on one line is exactly
    /// what this catches.
    private static func cockpitFailed() -> some View {
        let pass = ReviewPass(
            id: "structural",
            name: "Late structural read before the Melbourne submission",
            brief: "b",
            editorName: "Perkins")
        return ReviewRoundCockpit(
            passes: [pass],
            activePassId: pass.id,
            round: 12,
            coach: nil,
            phase: .failed(.cliNotFound, at: Date(timeIntervalSince1970: 1_750_000_000)),
            // Non-nil on purpose: the failure REPLACES it, so a strip that drew
            // both would be measured here as well as caught by
            // `ReviewRoundCockpitTests`' co-render test.
            reportLine: "Since round 11: 14 resolved \u{00b7} 9 persisting "
                + "\u{00b7} 21 new",
            onRun: { _ in },
            onSetActivePass: { _ in },
            onCancel: {})
    }

    func test_theRoundCockpitFitsTheColumnWithAFailedRound() {
        for width in Self.columnWidths {
            let measured = Self.width(of: Self.cockpitFailed(), proposing: width)
            XCTAssertLessThanOrEqual(
                measured, width + Self.slack,
                "the round cockpit's failed arm wants \(measured)pt in a "
                + "\(width)pt column \u{2014} the failure sentence must wrap "
                + "like every other line in the strip, not set its width")
        }
    }

    func test_theRoundCockpitsFailedArmHasRoomToSpareBelowTheColumnFloor() {
        let columnFloor = CGFloat(UIState.detailColumnWidthRange.lowerBound)
        let stripFloor = Self.width(of: Self.cockpitFailed(), proposing: 1)
        XCTAssertLessThanOrEqual(
            stripFloor + Self.headroom, columnFloor,
            "the failed strip cannot be drawn narrower than \(stripFloor)pt "
            + "against a \(columnFloor)pt column \u{2014} under the "
            + "\(Self.headroom)pt this suite asks for. An incompressible "
            + "failure line takes the margin all at once.")
    }

    // MARK: - The nudge (pass-order nudge gains its verbs, 2026-08-19)

    /// **The nudge's hardest honest case**: a pass the writer named at
    /// length, drawn beside its two new buttons. `PassOrderNudgeRow`'s `Text`
    /// wraps (`.fixedSize(horizontal: false, vertical: true)`), so this is
    /// really asking whether Mark done + Skip + the icon are compressible
    /// enough to leave the wrapping `Text` room in the narrowest column a
    /// writer can drag to.
    private static func nudgeRow(passName: String = "Structural") -> some View {
        PassOrderNudgeRow(
            pass: ReviewPass(id: "structural", name: passName),
            onMarkDone: {}, onSkip: {})
    }

    func test_theNudgeRowFitsTheColumn() {
        for width in Self.columnWidths {
            let measured = Self.width(of: Self.nudgeRow(), proposing: width)
            XCTAssertLessThanOrEqual(
                measured, width + Self.slack,
                "the pass-order nudge wants \(measured)pt in a \(width)pt "
                + "column \u{2014} its two buttons are `.controlSize(.mini)` "
                + "and the caption wraps, so an overflow here means one of "
                + "them stopped being compressible")
        }
    }

    /// The same headroom rule every other strip in this pane answers to.
    func test_theNudgeRowHasRoomToSpareBelowTheColumnFloor() {
        let columnFloor = CGFloat(UIState.detailColumnWidthRange.lowerBound)
        let rowFloor = Self.width(of: Self.nudgeRow(), proposing: 1)
        XCTAssertLessThanOrEqual(
            rowFloor + Self.headroom, columnFloor,
            "the nudge cannot be drawn narrower than \(rowFloor)pt, which "
            + "leaves \(columnFloor - rowFloor)pt of slack in the narrowest "
            + "column a writer can drag to \u{2014} under the "
            + "\(Self.headroom)pt this suite asks for. A third button on "
            + "this row wants a wider pane rather than a second line.")
    }

    /// A writer's own pass name is unbounded (`ReviewPassEditorLogic` puts no
    /// ceiling on it) and the row's `Text` is what has to absorb that, not
    /// the two buttons beside it.
    func test_aWriterNamedPassDoesNotWidenTheNudgeRow() {
        let long = "Second pass \u{2014} continuity, timeline and the dog"
        for width in Self.columnWidths {
            let measured = Self.width(
                of: Self.nudgeRow(passName: long), proposing: width)
            XCTAssertLessThanOrEqual(
                measured, width + Self.slack,
                "a \(long.count)-character pass name took the nudge to "
                + "\(measured)pt in a \(width)pt column \u{2014} the caption "
                + "must wrap, not set the row's width")
        }
    }

    /// **Without this, the two assertions above could be measuring nothing.**
    /// The instrument's own control, this suite's established idiom
    /// (`test_theInstrumentSeesAnIncompressibleRow`): plant an incompressible
    /// row shaped like the nudge (a `.fixedSize()` worded label beside two
    /// `.fixedSize()` buttons) and require it to overflow, so a silently
    /// no-op measurement cannot pass by never seeing the defect it claims to
    /// rule out.
    func test_theInstrumentSeesAnIncompressibleNudgeRow() {
        for width in Self.columnWidths {
            let planted = Self.width(of: FixedSizeNudgeRow(), proposing: width)
            XCTAssertGreaterThan(
                planted, width * 1.2,
                "the planted offender \u{2014} a `.fixedSize()` caption "
                + "beside two `.fixedSize()` buttons \u{2014} must overflow a "
                + "\(width)pt column, or this suite's instrument cannot see "
                + "the bug it is asserting the absence of")
        }
    }

    /// **What the measurements above cannot see.** Mounts
    /// `PassOrderNudgeRow` directly, so they would stay green the day
    /// `AnnotationsPane.passOrderNudge` went back to composing its own row —
    /// the toolbar's own established idiom
    /// (`test_theQueuesToolbarIsTheViewThisSuiteMeasures`).
    func test_theNudgeIsTheViewThisSuiteMeasures() throws {
        let code = try Self.codeLines(of: "Views/AnnotationsPane.swift")
        XCTAssertEqual(
            code.filter { $0.contains("PassOrderNudgeRow(") }.count, 1,
            "the pane must render its advisory nudge through the extracted "
            + "row, once — an inline composition here is a second row with "
            + "no width measurement on it")
    }

    /// The offender's mechanism, not a byte copy of the shipped row.
    private struct FixedSizeNudgeRow: View {
        var body: some View {
            HStack(spacing: 6) {
                Text("Structural still open on this piece, a caption long "
                    + "enough that wrapping is the only honest way to fit it")
                    .fixedSize()
                Button("Mark done") {}.fixedSize()
                Button("Skip") {}.fixedSize()
            }
            .padding(.horizontal, 12)
        }
    }

    /// And the diff card inside it, which is what Denver saw running off the
    /// right edge. Its `Text`s were always compressible — this pins that they
    /// stay so, independently of what the toolbar above them does.
    func test_theDiffCardWrapsInsteadOfRunningPastTheEdge() {
        let row = AnnotationRow(
            annotation: Self.suggestion,
            onAccept: {}, onReject: {}, onArchive: {}, onReply: {},
            onJumpToParagraph: {})
        for width in Self.columnWidths {
            let size = Self.size(of: row, proposing: width)
            XCTAssertLessThanOrEqual(
                size.width, width + Self.slack,
                "the suggestion's monospaced diff lines must wrap into the "
                + "column, not set its width (\(size.width)pt at \(width)pt)")
            XCTAssertGreaterThan(
                size.height, 120,
                "premise: the long prior and suggested paragraphs actually "
                + "wrapped onto many lines — a short card would satisfy the "
                + "width claim above by having nothing to wrap")
        }
    }

    /// A long suggestion, so the diff card has real text to wrap. Both halves
    /// run past a narrow column many times over.
    private static let suggestion = Annotation(
        id: "a1", kind: .suggestedChange, paragraphId: "3k7p",
        body: "The paragraph leans on the same construction three times "
            + "running; varying it would let the last clause land.",
        suggestedText: "She had not expected the door to be open, and the "
            + "fact that it was told her more about the evening than "
            + "anything she would be told later, by anyone, in words.",
        priorText: "She did not expect the door to be open. The door was "
            + "open. She did not know what to make of the door being open, "
            + "and she stood there for a while not making anything of it.",
        createdAt: Date(timeIntervalSince1970: 1_750_000_000),
        createdBySession: nil, status: .open, userResponse: nil,
        resolvedAt: nil, isStale: false)

    // MARK: - The instrument

    /// What SwiftUI lays this view out at when offered `width`. The height
    /// proposal is generous on purpose: the question is only ever horizontal,
    /// and a squeezed height would make a row wrap differently than it does in
    /// a scrolling pane.
    private static func size(of view: some View, proposing width: CGFloat) -> CGSize {
        let controller = NSHostingController(rootView: AnyView(view))
        _ = controller.view
        return controller.sizeThatFits(
            in: CGSize(width: width, height: 4000))
    }

    private static func width(of view: some View, proposing width: CGFloat) -> CGFloat {
        size(of: view, proposing: width).width
    }

    /// **What the content asks for before any column squeezes it.**
    ///
    /// `sizeThatFits` cannot answer this: the toolbar's one-line variant holds a
    /// `Spacer`, so it fills whatever it is proposed and a 4000pt proposal comes
    /// back as 4000. `intrinsicContentSize` is SwiftUI's ideal under an
    /// unspecified proposal, which is where a `ViewThatFits` reports its FIRST
    /// child — exactly the variant a fit assertion at 240pt never touches, and
    /// exactly where the ceiling defect was hiding.
    private static func idealWidth(of view: some View) -> CGFloat {
        NSHostingView(rootView: AnyView(view)).intrinsicContentSize.width
    }

    // MARK: - The instrument's own control

    /// **Without this, every assertion above could be measuring nothing.** A
    /// `sizeThatFits` that simply echoed its proposal back would make the whole
    /// suite green over a pane clipped exactly as badly as Denver found it.
    ///
    /// So: a row built to be incompressible the way the shipped toolbar was —
    /// worded `.fixedSize()` borderless menus in an `HStack` — must come back
    /// WIDER than any column it is offered, and the same row in icon form must
    /// come back narrower. This is the defect's mechanism, kept measurable.
    func test_theInstrumentSeesAnIncompressibleRow() {
        for width in Self.columnWidths {
            let worded = Self.width(of: FixedSizeRow(useIcons: false),
                                    proposing: width)
            XCTAssertGreaterThan(
                worded, width * 1.5,
                "the planted offender — six worded `.fixedSize()` menus, the "
                + "shape the toolbar shipped in — must overflow a \(width)pt "
                + "column by a wide margin, or this suite's instrument cannot "
                + "see the bug it is asserting the absence of")

            let iconic = Self.width(of: FixedSizeRow(useIcons: true),
                                    proposing: width)
            XCTAssertLessThanOrEqual(
                iconic, width + Self.slack,
                "and the control on the control: the same row in icon form "
                + "fits, so the instrument is not simply answering 'too wide' "
                + "to everything")
        }
    }

    // MARK: - The census: the pane's toolbar is the one that was measured

    /// **What every measurement above cannot see.** This suite mounts
    /// `AnnotationsQueueToolbar` directly, so all of it would stay green the day
    /// `AnnotationsPane` went back to composing a row of its own — which is
    /// exactly how the defect arrived the first time, one control at a time.
    /// One line, tying the thing that is measured to the thing that ships.
    func test_theQueuesToolbarIsTheViewThisSuiteMeasures() throws {
        let code = try Self.codeLines(of: "Views/AnnotationsPane.swift")
        XCTAssertEqual(
            code.filter { $0.contains("AnnotationsQueueToolbar(") }.count, 1,
            "the pane must render its filters through the extracted toolbar, "
            + "once — an inline row here is a second composition with no width "
            + "measurement on it")
    }

    private static var appSourceDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MaughamTests/Views/
            .deletingLastPathComponent()   // MaughamTests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Maugham", isDirectory: true)
    }

    private static func codeLines(of relativePath: String) throws -> [String] {
        let url = appSourceDir.appendingPathComponent(relativePath)
        return SourceScan.codeLines(of: try String(contentsOf: url, encoding: .utf8))
    }

    /// The offender's mechanism, not a byte copy of the shipped toolbar — what
    /// makes a row incompressible is `.fixedSize()` over labels that carry
    /// words, and that is what this is.
    private struct FixedSizeRow: View {
        let useIcons: Bool
        private static let words = ["All Pieces", "Structural", "Triage",
                                    "Author", "Resolved", "Selection"]
        var body: some View {
            HStack(spacing: 0) {
                ForEach(Self.words, id: \.self) { word in
                    Menu {
                        Button("\u{2026}") {}
                    } label: {
                        if useIcons {
                            Image(systemName: "flag").font(.caption)
                        } else {
                            Label(word, systemImage: "flag").font(.caption)
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            .padding(.horizontal, 8)
        }
    }
}
