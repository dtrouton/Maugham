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

/// **The one-segment left column, measured rather than reasoned about.**
///
/// Slice 2 of the persona shell (§6.1 of
/// `docs/superpowers/specs/2026-08-01-persona-shell-workflow-design.md`) takes
/// Review and Publish down to a single binder segment. The reconnaissance read
/// `BinderSegmentPicker.body` — a `[BinderSegment]` fed to a `ForEach` inside a
/// segmented `Picker` — and marked the single-button rendering **unverified by
/// measurement**. It is verified here, on the real `NSSegmentedControl` SwiftUI
/// builds: how many segments it has, that the one segment carries its image, that
/// it is selected, and that it does not stretch the whole 240pt column.
///
/// It matters because a segmented control's failure modes at count 1 are all
/// silent: a control with `segmentCount == 0`, a segment with no image, or one
/// with nothing selected all *render* — they just render as broken chrome, which
/// is the exact worry `Persona.swift`'s Publish case argued about for a slice and
/// nobody put a number on.
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

    // MARK: - Count 1 renders as one real, selected, sized segment

    /// `.author` joined `.review` and `.publish` here in task 6b (§6.1). Task 6
    /// measured the one-segment shape and there is nothing to re-measure — this
    /// asks only whether **Author specifically** is different, since it is the
    /// default persona and the one an upgrading writer opens into.
    func test_aOneSegmentPickerRendersExactlyOneSegment() async throws {
        for persona in [Persona.review, .publish, .author] {
            XCTAssertEqual(BinderSegmentPicker.visibleSegments(
                persona: persona, projectType: .novel,
                hasTrash: false, findActive: false).count, 1,
                "premise: \(persona) is the one-segment case")

            let control = try await mount(persona: persona, on: .manuscript)
            XCTAssertEqual(control.segmentCount, 1,
                           "\(persona): a one-element ForEach must produce one "
                           + "segment, not zero and not a collapsed control")
            XCTAssertNotNil(control.image(forSegment: 0),
                            "\(persona): the segment must carry its symbol — an "
                            + "imageless segment is an invisible button")
            XCTAssertEqual(control.selectedSegment, 0,
                           "\(persona): nothing highlighted is the defect the "
                           + "right pane's picker already shipped once")
        }
    }

    /// It is a BUTTON, not a bar. A single segment stretched across the whole
    /// column reads as a header rather than a control, which is the "broken
    /// chrome" shape argued about in prose for a whole slice; a single segment
    /// sized like any other reads as a picker with one choice in it.
    ///
    /// **Measured 2026-08-02, macOS 26.5:** the one-segment control lays out at
    /// **24 × 24 pt** inside a 240pt column — so the segmented control hugs its
    /// content rather than filling the column. Consistent with the 87–145pt
    /// figures already recorded at `BinderSegment.pickerSymbolName`, which is
    /// how we know this measurement is reading the real control. Plan's own
    /// width is not written down: it moves with its segment list (slice 2 added
    /// one), and the assertion below compares the two rather than pinning
    /// either.
    ///
    /// **Plan's segment count is asked, never asserted as a literal.** It read
    /// `XCTAssertEqual(three.segmentCount, 3)` and slice 2's `.tree` made it 4 —
    /// a count over a list, the shape
    /// `memory/feedback_prose_counts_are_unmaintainable.md` is about. What this
    /// test needs of Plan is only that it has MORE segments than the
    /// single-segment personas, which is the premise the width comparison rests
    /// on; the exact list is `PersonaBinderSegmentTests`' business.
    func test_theOneSegmentDoesNotStretchTheWholeColumn() async throws {
        let one = try await mount(persona: .review, on: .manuscript)
        let many = try await mount(persona: .plan, on: .canvas)

        XCTAssertEqual(many.segmentCount,
                       BinderSegmentPicker.visibleSegments(
                        persona: .plan, projectType: .novel,
                        hasTrash: false, findActive: false).count,
                       "what is drawn and what `visibleSegments` says must agree")
        XCTAssertGreaterThan(many.segmentCount, one.segmentCount,
                             "premise: Plan is the multi-segment case, and if it "
                             + "ever stops being one this comparison measures "
                             + "nothing")
        let oneWidth = one.frame.width
        let manyWidth = many.frame.width
        XCTAssertGreaterThan(oneWidth, 0, "the control must have laid out at all")
        XCTAssertLessThan(oneWidth, 240,
                          "a single segment must not fill the 240pt binder column")
        XCTAssertLessThan(oneWidth, manyWidth,
                          "and it must be narrower than Plan's picker — measured "
                          + "\(oneWidth)pt against \(manyWidth)pt over "
                          + "\(many.segmentCount) segments")
    }

    /// **The icon-only picker's only text, read off the real control.** At count
    /// 1 the whole left column is one 24pt glyph, so the tooltip is the entire
    /// answer to "what is this button" — an empty one would leave a writer with
    /// an unlabelled square and no picker to compare it against.
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
        for (persona, selected) in [(Persona.review, BinderSegment.manuscript),
                                    (.publish, .manuscript),
                                    (.author, .manuscript),
                                    (.plan, .canvas)] {
            let control = try await mount(persona: persona, on: selected)
            let expected = BinderSegmentPicker.visibleSegments(
                persona: persona, projectType: .novel,
                hasTrash: false, findActive: false, including: selected)
                .map { $0.displayName(for: .novel) }

            let actual = (0..<control.segmentCount).map { control.toolTip(forSegment: $0) }
            XCTAssertEqual(actual, expected.map(Optional.some),
                           "\(persona): every segment must name itself, at its own "
                           + "index — the tooltip is the only text this picker has")
        }
    }

    /// **The control.** The same mount at counts 1, 2 and 3, so the count-1
    /// assertions above are reading something that varies rather than a constant
    /// the harness would produce for any input.
    ///
    /// **Author moved from 2 to 1 in task 6b** (§6.1 — palette followed research
    /// off its left column), which took the last persona whose own registry
    /// offers exactly two segments. The count-2 row is therefore driven by
    /// `hasTrash`, which is persona-independent and is a real rendering rather
    /// than a stand-in — the same lever
    /// `test_theOneSegmentPersonaStillGrowsForTrashAndFind` uses.
    ///
    /// **Every expectation is ASKED of `visibleSegments`, and the control is
    /// that the answers differ.** The table carried literal counts (1, 1, 2, 3)
    /// and slice 2's `.tree` made the last one 4 — a count over a list. What
    /// this test is for is the harness reading something that varies rather than
    /// a constant, and "more than one distinct count, including a 1" says that
    /// without any number having to be maintained.
    func test_theSegmentCountTracksTheRenderedList() async throws {
        var observed: [Int] = []
        for (persona, selected, hasTrash) in [
            (Persona.review, BinderSegment.manuscript, false),
            (.author, .manuscript, false),
            (.author, .manuscript, true),
            (.plan, .canvas, false)
        ] as [(Persona, BinderSegment, Bool)] {
            let expected = BinderSegmentPicker.visibleSegments(
                persona: persona, projectType: .novel,
                hasTrash: hasTrash, findActive: false).count
            let control = try await mount(persona: persona, on: selected, hasTrash: hasTrash)
            XCTAssertEqual(
                control.segmentCount, expected,
                "\(persona) trash=\(hasTrash): what is drawn and what "
                + "`visibleSegments` says must be the same list")
            observed.append(control.segmentCount)
        }
        XCTAssertGreaterThan(Set(observed).count, 1,
                             "the control: a harness that returned the same "
                             + "count for every input would satisfy every "
                             + "assertion above — observed \(observed)")
        XCTAssertTrue(observed.contains(1),
                      "and the one-segment shape must be among what was "
                      + "rendered, or the count-1 tests above are measuring a "
                      + "case this harness never produces")
    }

    /// And the runtime-gated segments still reach a one-segment persona, so
    /// Review mid-search is a two-segment picker rather than a stranded one.
    func test_theOneSegmentPersonaStillGrowsForTrashAndFind() async throws {
        let control = try await mount(persona: .review, on: .manuscript,
                                      hasTrash: true, findActive: true)
        XCTAssertEqual(control.segmentCount, 3,
                       "Trash and Find are persona-INDEPENDENT — a reviewer "
                       + "mid-search keeps the Find segment")
    }

    // MARK: - A forced selection the persona does not offer still renders

    /// The asymmetry §6.1 leaves behind, driven through the real control rather
    /// than through `visibleSegments` alone. `ProjectWindow.openResearchItem`
    /// (**Open** on a promoted canvas card) and `handleShowLatestMCPNote`
    /// (**Show** on the MCP note banner) both set `binderSegment = .research`
    /// without consulting the persona. In Author, which no longer offers it,
    /// the appended segment must appear AND be the selected one.
    ///
    /// **`.palette` is here too as of task 6b**, and it arrives by a third route
    /// no event fires: `ProjectWindow.loadProject` restores `UIState.binderSegment`
    /// verbatim, so a project last quit in Author on the palette wall reopens
    /// there once, on the build that takes the segment away. Author renders one
    /// segment of its own now, so both cases are counts of 2 rather than 3.
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

    /// The same, in the one-segment personas: Review and Publish grow a second
    /// segment rather than swallowing the selection.
    func test_aForcedResearchSelectionRendersInTheOneSegmentPersonas() async throws {
        for persona in [Persona.review, .publish] {
            let control = try await mount(persona: persona, on: .research)
            XCTAssertEqual(control.segmentCount, 2, "\(persona)")
            XCTAssertEqual(control.selectedSegment, 1, "\(persona)")
        }
    }

    /// **Planted offender.** If `visibleSegments` ever stopped appending the
    /// current selection, the picker would render without it — and this proves
    /// the assertions above can see that, rather than passing on any input.
    func test_plantedOffender_withoutTheAppendTheForcedSegmentIsNotThere() async throws {
        let withoutAppend = BinderSegmentPicker.visibleSegments(
            persona: .author, projectType: .novel, hasTrash: false, findActive: false)
        XCTAssertFalse(withoutAppend.contains(.research),
                       "the offender: no append, no Research")

        let control = try await mount(persona: .author, on: .manuscript)
        XCTAssertEqual(control.segmentCount, withoutAppend.count,
                       "and it is 2 rather than 3 on screen, so the 3 asserted "
                       + "above is the append and not a coincidence")
    }

    // MARK: - Clicking still works at count 1

    /// A one-segment picker whose one segment is already selected has nothing to
    /// write, so the useful drive is the two-segment case a forced selection
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
        let frame = CGRect(x: 0, y: 0, width: 240, height: 60)
        let hosting = NSHostingView(rootView: AnyView(
            PickerProbeView(probe: probe, persona: persona, projectType: projectType,
                            hasTrash: hasTrash, findActive: findActive)))
        hosting.frame = frame
        let window = NSWindow(contentRect: frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        windows.append(window)
        await pumpUntil(deadline: 5) { self.firstSegmentedControl(in: window) != nil }
        return try XCTUnwrap(firstSegmentedControl(in: window),
                             "the picker's NSSegmentedControl never reached the "
                             + "hierarchy — a `Picker` that renders nothing is "
                             + "the failure this whole file exists to see")
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
