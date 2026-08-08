import XCTest
import AppKit
import SwiftUI
import Observation
import MaughamCore
@testable import Maugham

/// Holds the picker's binding outside the view, so a test can watch what a real
/// click on a real `NSSegmentedControl` writes through it.
@Observable
@MainActor
final class BinderSegmentProbe {
    var segment: BinderSegment
    init(_ segment: BinderSegment) { self.segment = segment }
}

/// Holds the two runtime-gated inputs outside the view, so a test can flip one
/// on a mounted picker and watch the control appear or disappear — the
/// transient join/leave contract needs the SAME mount observed twice, not two
/// separate mounts that could each be measuring a coincidence. At file scope
/// for the same reason as `BinderSegmentProbe`: `@Observable` cannot expand
/// inside a `private` nested type.
@Observable
@MainActor
final class BinderPickerVisibilityProbe {
    var hasTrash: Bool
    var findActive: Bool
    init(hasTrash: Bool = false, findActive: Bool = false) {
        self.hasTrash = hasTrash
        self.findActive = findActive
    }
}

@MainActor
private struct PickerProbeView: View {
    let probe: BinderSegmentProbe
    let persona: Persona
    let projectType: ProjectType
    let hasTrash: Bool
    let findActive: Bool

    var body: some View {
        BinderSegmentPicker(
            segment: Binding(get: { probe.segment }, set: { probe.segment = $0 }),
            persona: persona,
            projectType: projectType,
            hasTrash: hasTrash,
            findActive: findActive)
        // The binder column's real width. The picker's `.padding(.horizontal, 10)`
        // is applied inside this, exactly as `BinderPaneToggle` mounts it.
        .frame(width: 240)
    }
}

/// Exactly what `BinderPaneToggle` and `CollectionBinderPaneToggle` mount
/// today: `BinderSegmentPicker` alone, with nothing of the caller's own
/// beside it. The `Divider()` beneath the segmented control is now the
/// picker's own (fix round 1 of shell-finish stage 1 task 2 folded it in —
/// see `BinderSegmentPicker.body`'s doc comment): a caller that mounted its
/// own `Divider()` alongside this, as both callers did until that fix, would
/// leave a 1pt hairline behind after the picker itself goes empty — the
/// strip's ghost, and Denver's complaint was about the strip existing at
/// all. This probe mirrors the real callers' shape exactly so the residue
/// this fix removed cannot silently come back through a rewritten caller.
@MainActor
private struct PickerAloneProbeView: View {
    let persona: Persona
    let projectType: ProjectType
    let hasTrash: Bool
    let findActive: Bool

    var body: some View {
        BinderSegmentPicker(
            segment: .constant(persona.binderHome(for: projectType)),
            persona: persona,
            projectType: projectType,
            hasTrash: hasTrash,
            findActive: findActive)
        .frame(width: 240)
    }
}

@MainActor
private struct VisibilityProbeView: View {
    let probe: BinderPickerVisibilityProbe
    let persona: Persona
    let projectType: ProjectType

    var body: some View {
        BinderSegmentPicker(
            segment: .constant(persona.binderHome(for: projectType)),
            persona: persona,
            projectType: projectType,
            hasTrash: probe.hasTrash,
            findActive: probe.findActive)
        .frame(width: 240)
    }
}

/// A stand-in for the per-persona content each caller switches to below the
/// picker (the manuscript tree, research, etc.) — deliberately arbitrary and
/// fixed-height, since what fix round 1's residue test is about is the
/// CHROME above the content, not the content itself.
@MainActor
private struct StandInContentView: View {
    var body: some View {
        Rectangle().fill(Color.clear).frame(width: 240, height: 400)
    }
}

/// **Exactly the wrapper shape `BinderPaneToggle` and
/// `CollectionBinderPaneToggle` use today**: `VStack(spacing: 0) {
/// BinderSegmentPicker(...); <content> }`, nothing of the caller's own
/// between the picker and its content. This is the shape fix round 1's
/// residue test is against, rather than the picker alone
/// (`PickerAloneProbeView`): a caller that re-adds its own `Divider()`
/// beside the picker call is a bug in the CALLER's body, and a picker-only
/// probe cannot see it — the picker was already correct before fix round 1,
/// the callers were not.
@MainActor
private struct CallerShapeProbeView: View {
    let persona: Persona
    let projectType: ProjectType
    let hasTrash: Bool
    let findActive: Bool

    var body: some View {
        VStack(spacing: 0) {
            BinderSegmentPicker(
                segment: .constant(persona.binderHome(for: projectType)),
                persona: persona,
                projectType: projectType,
                hasTrash: hasTrash,
                findActive: findActive)
            StandInContentView()
        }
        .frame(width: 240)
    }
}

/// The baseline: the same content, with no picker call above it at all —
/// what a choiceless `CallerShapeProbeView` must measure exactly equal to,
/// or the wrapper is reserving height nobody can see by eye.
@MainActor
private struct ContentAloneProbeView: View {
    var body: some View {
        VStack(spacing: 0) {
            StandInContentView()
        }
        .frame(width: 240)
    }
}

/// **Planted offender, kept only as a test fixture — never mirror this in
/// production.** Reproduces the exact shape `BinderPaneToggle` and
/// `CollectionBinderPaneToggle` had BEFORE fix round 1 of shell-finish stage
/// 1 task 2: a `Divider()` mounted unconditionally right after the picker,
/// independent of whether the picker itself rendered anything. Exists solely
/// to prove the geometric test below can see the defect it exists to catch,
/// rather than passing on any input.
@MainActor
private struct HistoricalBuggyCallerShapeProbeView: View {
    let persona: Persona
    let projectType: ProjectType
    let hasTrash: Bool
    let findActive: Bool

    var body: some View {
        VStack(spacing: 0) {
            BinderSegmentPicker(
                segment: .constant(persona.binderHome(for: projectType)),
                persona: persona,
                projectType: projectType,
                hasTrash: hasTrash,
                findActive: findActive)
            Divider()
            StandInContentView()
        }
        .frame(width: 240)
    }
}

/// **The one-segment left column, measured rather than reasoned about.**
///
/// Slice 2 of the persona shell (§6.1 of
/// `docs/superpowers/specs/2026-08-01-persona-shell-workflow-design.md`) took
/// Review and Publish down to a single binder segment, and Author followed in
/// task 6b. The reconnaissance for that slice read `BinderSegmentPicker.body`
/// and marked the single-button rendering **unverified by measurement**; it
/// verified a real, selected, non-stretching `NSSegmentedControl` at count 1.
///
/// **Shell-finish stage 1 (`docs/superpowers/specs/2026-08-08-shell-finish-design.md`
/// §9) overturns that measurement on purpose**: "a picker exists only where a
/// real choice exists," so a one-segment (or zero-segment) list now renders
/// **nothing** — no `NSSegmentedControl` reaches the hierarchy at all. What
/// stays true from the original recon and is still worth measuring here: how
/// many segments a *multi*-segment mount produces, that each carries its
/// image and tooltip, that the selected one is highlighted, and that the
/// control never stretches the whole 240pt column. What is NEW is the
/// choiceless half — absence, layout (not just absence), and both directions
/// of a transient joining and leaving.
///
/// **What a mounted SwiftUI picker will and will not tell you, measured
/// 2026-08-02 on macOS 26.5 so the next person does not spend the afternoon on
/// it.** It *will*: `segmentCount`, `selectedSegment`, `image(forSegment:)` (a
/// 14×16 template image — `name()` is nil, so test the image and not its name,
/// or an optional chain collapses to `nil` and reads as "no image"), the
/// control's laid-out frame, and — the surprise — `toolTip(forSegment:)`, which
/// `.help()` does reach. It will *not*: `label(forSegment:)` is nil, because the
/// picker is deliberately icon-only; and the accessibility tree stops at one
/// `AXRadioGroup` `Cell` child whose `accessibilityLabel()` is nil, so
/// `.accessibilityLabel()` is unreadable from here and stays pinned by value in
/// `PersonaBinderSegmentTests.test_everySegmentHasANonEmptyDisplayNameForEveryProjectType`.
@MainActor
final class BinderSegmentPickerMountTests: XCTestCase {

    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        for window in windows { window.contentView = NSView(frame: .zero) }
        pump(0.05)
        windows.removeAll()
    }

    // MARK: - A choiceless picker renders nothing

    /// **The registry, not literals** (shell-finish stage 1 task 2's own
    /// contract): every persona's expected count comes from
    /// `Persona.binderSegments(for:)` itself, never a number written here, so
    /// this test cannot drift the way a hardcoded "Author is 1, Plan is 4"
    /// table would the next time a registry changes.
    ///
    /// A choiceless persona (count ≤ 1 — today Author, Review, Publish) must
    /// mount NO `NSSegmentedControl`. A multi-segment persona (today only
    /// Plan) must mount exactly as many segments as its registry lists.
    func test_choicelessPersonasRenderNothingMultiSegmentPersonasRenderTheirCount() async throws {
        var sawChoiceless = false
        var sawMultiSegment = false
        for persona in Persona.allCases {
            let expectedCount = persona.binderSegments(for: .novel).count
            let control = try await tryMount(persona: persona,
                                              on: persona.binderHome(for: .novel))
            if expectedCount <= 1 {
                sawChoiceless = true
                XCTAssertNil(control,
                             "\(persona): a choiceless picker (\(expectedCount) "
                             + "segment) must render nothing")
            } else {
                sawMultiSegment = true
                XCTAssertEqual(control?.segmentCount, expectedCount, "\(persona)")
            }
        }
        XCTAssertTrue(sawChoiceless,
                      "the control: this run must exercise at least one "
                      + "choiceless persona or the nil assertions above never fired")
        XCTAssertTrue(sawMultiSegment,
                      "the control: this run must exercise at least one "
                      + "multi-segment persona (Plan) or the count assertions "
                      + "above never fired")
    }

    /// **Plan unchanged, asked rather than pinned.** Stage 1's interim rule is
    /// about choice count, not persona identity — Plan already has four
    /// segments and stays a real picker. Asked of the registry so a future
    /// change to Plan's own list updates this test's expectation instead of
    /// breaking it.
    func test_planStillRendersARealMultiSegmentPicker() async throws {
        let expected = Persona.plan.binderSegments(for: .novel)
        XCTAssertGreaterThan(expected.count, 1,
                             "premise: Plan is still the multi-segment case")
        let control = try await mount(persona: .plan, on: .canvas)
        XCTAssertEqual(control.segmentCount, expected.count)
        XCTAssertEqual(control.selectedSegment, 0)
    }

    /// **Layout, not just absence.** A choiceless mount must not merely fail
    /// to produce an `NSSegmentedControl`; the PICKER ITSELF must reserve
    /// exactly ZERO vertical space, full stop. `NSHostingView.fittingSize`
    /// reads the laid-out AppKit tree, not the SwiftUI view's declared body,
    /// so this catches a footgun a purely structural check (asserting `body`
    /// returns `EmptyView`) would miss: `.padding` applied OUTSIDE the
    /// visibility check would still add its vertical inset around a
    /// zero-size child.
    ///
    /// **This test is necessarily blind to a caller-owned residue** — a
    /// `Divider()` a CALLER mounts unconditionally beside the picker call is
    /// a bug in the caller's body, not the picker's, and `PickerAloneProbeView`
    /// never mounts a caller at all. `BinderSegmentPicker` was already
    /// correct in isolation before fix round 1 (this exact assertion passed
    /// against the pre-fix-round-1 tree — it is the WRAPPER that was
    /// wrong); `test_theCallerWrapperAddsNoResidueBeyondThePickerItself`
    /// below is the one that actually caught fix round 1's defect.
    func test_choicelessPickerReservesExactlyZeroHeight() async throws {
        let choiceless = try await fittingHeight(
            PickerAloneProbeView(persona: .author, projectType: .novel,
                                 hasTrash: false, findActive: false))
        XCTAssertEqual(choiceless, 0, accuracy: 0.5,
                       "a choiceless picker must reserve exactly zero height "
                       + "on its own")

        let shown = try await fittingHeight(
            PickerAloneProbeView(persona: .plan, projectType: .novel,
                                 hasTrash: false, findActive: false))
        XCTAssertGreaterThan(shown, 10,
                             "the control: a real picker (control + its own "
                             + "divider) must reserve visible height, or this "
                             + "comparison is measuring nothing")
    }

    /// **The gap, not just the bar.** The picker's own zero-height contract,
    /// proved above, cannot see a caller that mounts its OWN `Divider()`
    /// beside the picker call — fix round 1's actual defect, in both
    /// `BinderPaneToggle` and `CollectionBinderPaneToggle`. This measures the
    /// exact wrapper shape both real callers use, choiceless, against the
    /// same content with no picker call above it at all: they must be
    /// indistinguishable, to the pixel accuracy `fittingSize` affords — a
    /// true flush join, not "no bigger than a bare divider."
    ///
    /// The planted-offender control at the end reproduces the exact shape
    /// both callers had before fix round 1 and proves this assertion is not
    /// vacuous: it measures a real, nonzero residue.
    func test_theCallerWrapperAddsNoResidueBeyondThePickerItself() async throws {
        let baseline = try await fittingHeight(ContentAloneProbeView())
        let fixedWrapper = try await fittingHeight(
            CallerShapeProbeView(persona: .author, projectType: .novel,
                                 hasTrash: false, findActive: false))
        XCTAssertEqual(fixedWrapper, baseline, accuracy: 0.5,
                       "the caller's wrapper, choiceless, must add nothing at "
                       + "all above its content — not even a 1pt hairline, or "
                       + "the tree's header is not truly flush")

        let buggyWrapper = try await fittingHeight(
            HistoricalBuggyCallerShapeProbeView(
                persona: .author, projectType: .novel,
                hasTrash: false, findActive: false))
        XCTAssertGreaterThan(buggyWrapper, baseline + 0.5,
                             "the control: the pre-fix-round-1 shape (picker "
                             + "plus a caller's own unconditional Divider) "
                             + "must measure MORE than the baseline, or this "
                             + "test cannot tell a residue from none")
    }

    // MARK: - Count > 1 renders as real, selected, sized segments

    /// The same control shape the original recon measured, now exercised
    /// through a genuinely rendered multi-segment case rather than the
    /// one-segment personas that no longer mount anything.
    func test_aMultiSegmentPickerRendersEverySegmentImagedAndSelected() async throws {
        let control = try await mount(persona: .plan, on: .canvas)
        let expected = Persona.plan.binderSegments(for: .novel).count
        XCTAssertEqual(control.segmentCount, expected)
        for index in 0..<control.segmentCount {
            XCTAssertNotNil(control.image(forSegment: index),
                            "segment \(index) must carry its symbol — an "
                            + "imageless segment is an invisible button")
        }
        XCTAssertEqual(control.selectedSegment, 0,
                       "nothing highlighted is the defect the right pane's "
                       + "picker already shipped once")
    }

    /// It is a BUTTON, not a bar. A rendered picker with fewer segments than
    /// Plan's must not stretch across the whole column — the "broken chrome"
    /// shape argued about in prose for a whole slice.
    ///
    /// **Measured 2026-08-02, macOS 26.5:** a one-segment control laid out at
    /// **24 × 24 pt** inside a 240pt column, so the segmented control hugs its
    /// content rather than filling the column; that measurement is preserved
    /// here through the two-segment forced-selection case (Author's own
    /// segment plus an appended Research), which is the smallest picker that
    /// still renders under the choiceless rule. Plan's own width is not
    /// written down: it moves with its segment list, and the assertion below
    /// compares the two rather than pinning either.
    func test_aRenderedPickerDoesNotStretchTheWholeColumn() async throws {
        let fewer = try await mount(persona: .author, on: .research)
        let many = try await mount(persona: .plan, on: .canvas)

        XCTAssertEqual(many.segmentCount,
                       BinderSegmentPicker.visibleSegments(
                        persona: .plan, projectType: .novel,
                        hasTrash: false, findActive: false).count,
                       "what is drawn and what `visibleSegments` says must agree")
        XCTAssertGreaterThan(many.segmentCount, fewer.segmentCount,
                             "premise: Plan has more segments than Author's "
                             + "forced two, and if it ever stops being one this "
                             + "comparison measures nothing")
        let fewerWidth = fewer.frame.width
        let manyWidth = many.frame.width
        XCTAssertGreaterThan(fewerWidth, 0, "the control must have laid out at all")
        XCTAssertLessThan(fewerWidth, 240,
                          "a two-segment picker must not fill the 240pt binder column")
        XCTAssertLessThan(fewerWidth, manyWidth,
                          "and it must be narrower than Plan's picker — measured "
                          + "\(fewerWidth)pt against \(manyWidth)pt over "
                          + "\(many.segmentCount) segments")
    }

    /// **The icon-only picker's only text, read off the real control.** Only
    /// exercised through configurations that actually render: the
    /// choiceless personas need `hasTrash: true` to grow a second segment
    /// first, or there is no control to read a tooltip from.
    ///
    /// `.help()` DOES reach `NSSegmentedControl.toolTip(forSegment:)` — measured,
    /// because the reconnaissance assumed otherwise. `label(forSegment:)` is nil
    /// (icon-only, by design) and the accessibility tree in this host stops at
    /// one `AXRadioGroup` child with a nil label, so the tooltip is the only
    /// per-segment string readable from outside.
    ///
    /// It also, incidentally, watches 2026-07-25 defect C at the AppKit level:
    /// tooltip *i* must name segment *i*, which is the invariant a cached
    /// `_ConditionalContent` branch broke by leaving a label on a stale index.
    func test_everyRenderedSegmentCarriesItsOwnTooltip() async throws {
        for (persona, selected, hasTrash) in [
            (Persona.review, BinderSegment.manuscript, true),
            (.publish, .manuscript, true),
            (.author, .manuscript, true),
            (.plan, .canvas, false)
        ] as [(Persona, BinderSegment, Bool)] {
            let control = try await mount(persona: persona, on: selected, hasTrash: hasTrash)
            let expected = BinderSegmentPicker.visibleSegments(
                persona: persona, projectType: .novel,
                hasTrash: hasTrash, findActive: false, including: selected)
                .map { $0.displayName(for: .novel) }

            let actual = (0..<control.segmentCount).map { control.toolTip(forSegment: $0) }
            XCTAssertEqual(actual, expected.map(Optional.some),
                           "\(persona): every segment must name itself, at its own "
                           + "index — the tooltip is the only text this picker has")
        }
    }

    /// **The control.** The same mount at counts 0 (rendering nothing), 2 and
    /// 3, so the assertions elsewhere in this file are reading something that
    /// varies rather than a constant the harness would produce for any input.
    ///
    /// **Every expectation is ASKED of `visibleSegments`, and the control is
    /// that the answers differ**, including the choiceless case: a count ≤ 1
    /// must mount no control at all, never a control with that many segments.
    func test_theSegmentCountTracksTheRenderedListIncludingTheChoicelessCase() async throws {
        var observedNilCount = 0
        var observedCounts: [Int] = []
        for (persona, selected, hasTrash) in [
            (Persona.review, BinderSegment.manuscript, false),
            (.author, .manuscript, false),
            (.author, .manuscript, true),
            (.plan, .canvas, false)
        ] as [(Persona, BinderSegment, Bool)] {
            let expected = BinderSegmentPicker.visibleSegments(
                persona: persona, projectType: .novel,
                hasTrash: hasTrash, findActive: false).count
            let control = try await tryMount(persona: persona, on: selected, hasTrash: hasTrash)
            if expected <= 1 {
                observedNilCount += 1
                XCTAssertNil(control,
                             "\(persona) trash=\(hasTrash): a choiceless list "
                             + "(\(expected)) must mount no control")
            } else {
                XCTAssertEqual(control?.segmentCount, expected,
                               "\(persona) trash=\(hasTrash): what is drawn and "
                               + "what `visibleSegments` says must be the same list")
                observedCounts.append(expected)
            }
        }
        XCTAssertGreaterThan(observedNilCount, 0,
                             "the control: the choiceless case must be among "
                             + "what was exercised, or the nil assertions above "
                             + "never fired")
        XCTAssertGreaterThan(Set(observedCounts).count, 1,
                             "the control: a harness that returned the same "
                             + "count for every rendered input would satisfy "
                             + "every non-nil assertion above — observed "
                             + "\(observedCounts)")
    }

    /// And the runtime-gated segments still reach a choiceless persona, so
    /// Review mid-search is a two-segment picker rather than a stranded one —
    /// unchanged by stage 1, since Trash+Find joining is exactly what makes a
    /// choiceless list a real choice.
    func test_theChoicelessPersonaStillGrowsForTrashAndFind() async throws {
        let hidden = try await tryMount(persona: .review, on: .manuscript)
        XCTAssertNil(hidden, "premise: Review alone is choiceless")

        let control = try await mount(persona: .review, on: .manuscript,
                                      hasTrash: true, findActive: true)
        XCTAssertEqual(control.segmentCount, 3,
                       "Trash and Find are persona-INDEPENDENT — a reviewer "
                       + "mid-search keeps the Find segment")
    }

    // MARK: - Transient joining and leaving, driven on one mount

    /// **Both directions, on the SAME mounted picker.** Two separate mounts
    /// (one with the transient, one without) could each be measuring a
    /// coincidence of that particular mount rather than a real appear/disappear
    /// transition; flipping `BinderPickerVisibilityProbe`'s flags on a picker
    /// already on screen and re-observing is the only way to see the strip
    /// actually come and go.
    func test_transientJoiningAndLeavingTogglesThePickerBothDirections() async throws {
        let probe = BinderPickerVisibilityProbe()
        let window = mountVisibility(probe: probe, persona: .author, projectType: .novel)
        await pumpUntil(deadline: 2) { self.firstSegmentedControl(in: window) == nil }
        XCTAssertNil(firstSegmentedControl(in: window),
                     "premise: Author alone, no trash, no find — choiceless")

        probe.hasTrash = true
        await pumpUntil(deadline: 2) { self.firstSegmentedControl(in: window) != nil }
        XCTAssertNotNil(firstSegmentedControl(in: window),
                        "trash joining must make the picker appear")

        probe.hasTrash = false
        await pumpUntil(deadline: 2) { self.firstSegmentedControl(in: window) == nil }
        XCTAssertNil(firstSegmentedControl(in: window),
                     "and trash leaving must make it disappear again")

        probe.findActive = true
        await pumpUntil(deadline: 2) { self.firstSegmentedControl(in: window) != nil }
        XCTAssertNotNil(firstSegmentedControl(in: window),
                        "find joining must also make the picker appear")

        probe.findActive = false
        await pumpUntil(deadline: 2) { self.firstSegmentedControl(in: window) == nil }
        XCTAssertNil(firstSegmentedControl(in: window),
                     "and find leaving must also make it disappear")
    }

    // MARK: - A forced selection the persona does not offer still renders

    /// The asymmetry §6.1 leaves behind, driven through the real control rather
    /// than through `visibleSegments` alone. `ProjectWindow.openResearchItem`
    /// (**Open** on a promoted canvas card) and `handleShowLatestMCPNote`
    /// (**Show** on the MCP note banner) both set `binderSegment = .research`
    /// without consulting the persona. In Author, which no longer offers it,
    /// the appended segment must appear AND be the selected one.
    func test_aForcedSelectionRendersAndIsSelectedInAuthor() async throws {
        for forced in [BinderSegment.research, .palette] {
            XCTAssertFalse(Persona.author.binderSegments(for: .novel).contains(forced),
                           "premise: Author no longer offers \(forced) on the left")

            let control = try await mount(persona: .author, on: forced)
            XCTAssertEqual(control.segmentCount, 2,
                           "\(forced): Manuscript, and the appended segment")
            XCTAssertEqual(control.selectedSegment, 1,
                           "\(forced): appended last, and highlighted — a picker "
                           + "with nothing selected over a pane showing it is "
                           + "the defect")
        }
    }

    /// The same, in the choiceless personas: Review and Publish grow a second
    /// segment rather than swallowing the selection — and rather than staying
    /// hidden, since a forced selection not already in the list is exactly a
    /// second real choice.
    func test_aForcedResearchSelectionRendersInTheChoicelessPersonas() async throws {
        for persona in [Persona.review, .publish] {
            let control = try await mount(persona: persona, on: .research)
            XCTAssertEqual(control.segmentCount, 2, "\(persona)")
            XCTAssertEqual(control.selectedSegment, 1, "\(persona)")
        }
    }

    /// **Planted offender.** If `visibleSegments` ever stopped appending the
    /// current selection, the picker would render without it — and this proves
    /// the assertions above can see that, rather than passing on any input.
    /// Uses `.research` (not already in Author's own one-segment list) rather
    /// than `.manuscript`, which the choiceless rule now hides on its own and
    /// so cannot demonstrate the append at all.
    func test_plantedOffender_withoutTheAppendTheForcedSegmentIsNotThere() async throws {
        let withoutAppend = BinderSegmentPicker.visibleSegments(
            persona: .author, projectType: .novel, hasTrash: false, findActive: false)
        XCTAssertFalse(withoutAppend.contains(.research),
                       "the offender: no append, no Research")
        XCTAssertEqual(withoutAppend.count, 1,
                       "premise: Author's own list is choiceless without the append")

        let control = try await mount(persona: .author, on: .research)
        XCTAssertEqual(control.segmentCount, 2,
                       "the append turns a choiceless 1 into a real 2 on screen")
    }

    // MARK: - Clicking still works at count 1

    /// A one-segment picker whose one segment is already selected renders
    /// nothing under the choiceless rule (there is nothing to click), so the
    /// useful drive is still the two-segment case a forced selection
    /// produces: click segment 0 and the writer must leave Research.
    func test_clickingASegmentWritesThroughTheBinding() async throws {
        let probe = BinderSegmentProbe(.research)
        let control = try await mount(probe: probe, persona: .review, projectType: .novel,
                                      hasTrash: false, findActive: false)
        XCTAssertEqual(control.segmentCount, 2)

        control.selectedSegment = 0
        control.sendAction(control.action, to: control.target)
        await pumpUntil(deadline: 5) { probe.segment == .manuscript }

        XCTAssertEqual(probe.segment, .manuscript,
                       "the one offered segment must still be clickable — "
                       + "otherwise Review's forced Research is a trap")
    }

    // MARK: - Hosting

    private func mount(persona: Persona,
                       on segment: BinderSegment,
                       projectType: ProjectType = .novel,
                       hasTrash: Bool = false,
                       findActive: Bool = false) async throws -> NSSegmentedControl {
        try await mount(probe: BinderSegmentProbe(segment), persona: persona,
                        projectType: projectType, hasTrash: hasTrash, findActive: findActive)
    }

    private func mount(probe: BinderSegmentProbe,
                       persona: Persona,
                       projectType: ProjectType,
                       hasTrash: Bool,
                       findActive: Bool) async throws -> NSSegmentedControl {
        let window = mountWindow(PickerProbeView(probe: probe, persona: persona,
                                                 projectType: projectType,
                                                 hasTrash: hasTrash, findActive: findActive))
        await pumpUntil(deadline: 5) { self.firstSegmentedControl(in: window) != nil }
        return try XCTUnwrap(firstSegmentedControl(in: window),
                             "the picker's NSSegmentedControl never reached the "
                             + "hierarchy — a `Picker` that renders nothing is "
                             + "the failure this whole file exists to see")
    }

    /// The non-throwing counterpart, for configurations expected to render
    /// nothing under the choiceless rule: a plain `mount` would fail the test
    /// on every one of those cases via `XCTUnwrap`, which is exactly backwards
    /// when "no control" is the assertion being made.
    private func tryMount(persona: Persona,
                          on segment: BinderSegment,
                          projectType: ProjectType = .novel,
                          hasTrash: Bool = false,
                          findActive: Bool = false) async throws -> NSSegmentedControl? {
        let window = mountWindow(PickerProbeView(probe: BinderSegmentProbe(segment),
                                                 persona: persona, projectType: projectType,
                                                 hasTrash: hasTrash, findActive: findActive))
        // Give a real render pass a chance to produce a control before
        // concluding there is none — the same budget `pumpUntil` uses
        // elsewhere, just tolerant of the condition never becoming true.
        await pumpUntil(deadline: 1) { self.firstSegmentedControl(in: window) != nil }
        return firstSegmentedControl(in: window)
    }

    private func mountVisibility(probe: BinderPickerVisibilityProbe,
                                 persona: Persona,
                                 projectType: ProjectType) -> NSWindow {
        mountWindow(VisibilityProbeView(probe: probe, persona: persona, projectType: projectType))
    }

    private func mountWindow(_ view: some View) -> NSWindow {
        let frame = CGRect(x: 0, y: 0, width: 240, height: 60)
        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.frame = frame
        let window = NSWindow(contentRect: frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        windows.append(window)
        return window
    }

    /// `NSHostingView.fittingSize.height` for a probe view laid out at the
    /// binder column's real 240pt width — reads the laid-out AppKit tree
    /// rather than the SwiftUI view's declared body, which is the "layout,
    /// not just absence" measurement the choiceless contract asks for.
    private func fittingHeight(_ view: some View) async throws -> CGFloat {
        let frame = CGRect(x: 0, y: 0, width: 240, height: 200)
        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.frame = frame
        let window = NSWindow(contentRect: frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        windows.append(window)
        pump(0.1)
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize.height
    }

    private func firstSegmentedControl(in window: NSWindow) -> NSSegmentedControl? {
        guard let root = window.contentView else { return nil }
        var found: [NSSegmentedControl] = []
        collect(NSSegmentedControl.self, in: root, into: &found)
        return found.first
    }

    private func collect<T: NSView>(_ type: T.Type, in view: NSView, into out: inout [T]) {
        if let hit = view as? T { out.append(hit) }
        for sub in view.subviews { collect(type, in: sub, into: &out) }
    }
}

// MARK: - AX: commands reach their segment even while the picker is hidden

/// **Delivery-path check, not a structural one** (shell-finish stage 1 task
/// 2's fourth contract). `⌘⌥F`'s handler
/// (`ProjectWindow`'s `.onKeyWindowCommand(.maughamFindInProject)`) writes
/// `binderSegment = .find` directly — it never touches the picker, clicks a
/// segment, or consults `visibleSegments`. This mounts the real
/// `BinderPaneToggle`, starts it in a choiceless persona (Author, no trash, no
/// active find — the picker absent from the hierarchy), then drives the
/// segment binding exactly the way that handler does and confirms Find still
/// mounts. If the content pane depended on the picker being present to
/// deliver a selection, this would find no search field.
@MainActor
final class BinderSegmentPickerAXReachabilityTests: XCTestCase {

    private var temp: TempDirectory!
    private var windows: [NSWindow] = []

    override func setUp() async throws {
        temp = TempDirectory()
    }

    override func tearDown() async throws {
        for window in windows { window.contentView = NSView(frame: .zero) }
        pump(0.05)
        windows.removeAll()
        temp.cleanup()
        temp = nil
    }

    func test_findCommandStillReachesItsContentWhileThePickerIsHidden() async throws {
        let store = try await project(of: .novel)
        let box = TransientExitBox(segment: .manuscript, findActive: false)
        let window = host(AXProbeView(store: store, box: box, persona: .author))

        XCTAssertNil(firstSegmentedControl(in: window),
                     "premise: Author, no trash, no find — the picker is hidden")
        XCTAssertNil(firstTextField(placeholder: "Find in project", in: window),
                     "premise: Find is not open yet")

        // Mirrors `ProjectWindow`'s `.onKeyWindowCommand(.maughamFindInProject)`
        // handler verbatim: a direct write to the bound segment, nothing routed
        // through the picker or a click. It does not touch `findActive` either
        // — the production handler never does — so this is exactly what the
        // real command sends.
        box.segment = .find
        await waitOut(0.4)

        XCTAssertNotNil(firstTextField(placeholder: "Find in project", in: window),
                        "the Find command must still reach its content even "
                        + "though nothing in the strip was clickable to get there")

        // The picker itself is not the point of this contract (content
        // reachability is), but it is worth confirming `visibleSegments`'
        // append-the-current-selection rule still recovers a real choice on
        // its own: Author's one segment plus the now-selected `.find` is a
        // real second option, so the strip returns too.
        guard let control = firstSegmentedControl(in: window) else {
            return XCTFail("the picker should have grown a second segment "
                           + "(Author's own, plus the now-selected Find) once "
                           + "the command landed")
        }
        XCTAssertEqual(control.segmentCount, 2)
        XCTAssertEqual(control.selectedSegment, 1,
                       "Find must be the highlighted segment once it is the "
                       + "current one")
    }

    // MARK: - Hosting

    private func project(of type: ProjectType) async throws -> ProjectStore {
        let name = "\(type.rawValue)-\(UUID().uuidString.prefix(6))"
        let url = try await ProjectFactory.createNovelProject(named: name, in: temp.url)
        let store = try await ProjectStore.load(from: url)
        await store.wordCountPopulationTask?.value
        return store
    }

    private func host(_ view: some View) -> NSWindow {
        let frame = CGRect(x: 0, y: 0, width: 320, height: 600)
        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.frame = frame
        let window = NSWindow(contentRect: frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        windows.append(window)
        pump(0.15)
        return window
    }

    private func firstSegmentedControl(in window: NSWindow) -> NSSegmentedControl? {
        guard let root = window.contentView else { return nil }
        var found: [NSSegmentedControl] = []
        collect(NSSegmentedControl.self, in: root, into: &found)
        return found.first
    }

    private func firstTextField(placeholder: String, in window: NSWindow) -> NSTextField? {
        guard let root = window.contentView else { return nil }
        var found: [NSTextField] = []
        collect(NSTextField.self, in: root, into: &found)
        return found.first { $0.placeholderString == placeholder }
    }

    private func collect<T: NSView>(_ type: T.Type, in view: NSView, into out: inout [T]) {
        if let hit = view as? T { out.append(hit) }
        for sub in view.subviews { collect(type, in: sub, into: &out) }
    }

    private func waitOut(_ seconds: TimeInterval) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            pump(0.02)
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func pump(_ seconds: TimeInterval = 0.15) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}

/// The left column as `ProjectWindow.binderColumn` builds it, with the segment
/// and find flag hoisted out so a test can drive them exactly as the real
/// `.onKeyWindowCommand` handlers do. A local copy of
/// `TransientSegmentReturnTests`' `TransientExitProbeView` rather than a
/// shared one: that struct is `private` to its own file, and duplicating a
/// dozen lines of harness is cheaper than widening another suite's visibility
/// for one caller.
@MainActor
private struct AXProbeView: View {
    let store: ProjectStore
    let box: TransientExitBox
    let persona: Persona
    @State private var subject: BinderSubject?
    @State private var researchId: String?
    @State private var paletteCardId: String?

    private var segment: Binding<BinderSegment> {
        Binding(get: { box.segment }, set: { box.segment = $0 })
    }

    private var findActive: Binding<Bool> {
        Binding(get: { box.findActive }, set: { box.findActive = $0 })
    }

    var body: some View {
        BinderPaneToggle(
            store: store,
            segment: segment,
            selectedSubject: $subject,
            selectedResearchId: $researchId,
            selectedPaletteCardId: $paletteCardId,
            projectType: store.manifest.type,
            lastParsedScript: nil,
            findActive: findActive,
            persona: persona)
    }
}

// MARK: - Census: neither caller spells its own Divider() beside the picker

/// **The source half of the residue fix.** `Divider()` has no discoverable
/// `NSView` of its own — SwiftUI draws it directly rather than bridging an
/// `NSBox`, confirmed empirically before writing this file (a scratch mount
/// walking the real AppKit subview tree under a `Divider()` found none) — so
/// a runtime search for "is there a divider view" cannot exist; only a
/// `fittingSize` measurement (`test_theCallerWrapperAddsNoResidueBeyondThePickerItself`)
/// or a source read can see one. This is the source read: exactly one
/// `Divider()` in each caller, the Exports footer's own (gated on
/// `segment == .documentHome(for:)`), never a second one spelled
/// unconditionally beside `BinderSegmentPicker(...)` — the shape fix round 1
/// removed.
@MainActor
final class BinderSegmentPickerCallerDividerCensusTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    private func nonCommentDividerCount(in text: String) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: false).filter {
            let trimmed = $0.trimmingCharacters(in: .whitespaces)
            return !trimmed.hasPrefix("//") && trimmed.contains("Divider()")
        }.count
    }

    /// The control: a planted second `Divider()` line must change the count,
    /// or the census below is vacuous.
    func test_theCensusCanCountAPlantedDivider() {
        let clean = "        BinderSegmentPicker(...)\n        Group {"
        let planted = clean + "\n        Divider()"
        XCTAssertEqual(nonCommentDividerCount(in: clean), 0)
        XCTAssertEqual(nonCommentDividerCount(in: planted), 1)
        XCTAssertEqual(nonCommentDividerCount(in: planted + "\n        Divider()"), 2,
                       "a second planted Divider() must also be counted")
    }

    /// **Exactly one `Divider()` per caller.** Fix round 1 of shell-finish
    /// stage 1 task 2 removed the unconditional one that used to sit right
    /// after `BinderSegmentPicker(...)` — the one that survived even when the
    /// picker itself rendered nothing, leaving the strip's ghost.
    /// `BinderSegmentPicker.body` now folds its own `Divider()` in (see its
    /// doc comment), so neither caller should ever spell one of its own
    /// beside the picker call again.
    func test_eachCallerSpellsExactlyOneDividerTheExportsFootersOwn() throws {
        for path in ["Maugham/Views/BinderPaneToggle.swift",
                     "Maugham/Views/CollectionBinderPaneToggle.swift"] {
            let text = try source(path)
            XCTAssertFalse(text.isEmpty, "\(path): read nothing")
            let count = nonCommentDividerCount(in: text)
            XCTAssertEqual(count, 1,
                           "\(path): expected exactly one Divider() — the "
                           + "Exports footer's — found \(count). A second one "
                           + "right after BinderSegmentPicker(...) is the "
                           + "ghost-divider defect fix round 1 removed.")
        }
    }
}
