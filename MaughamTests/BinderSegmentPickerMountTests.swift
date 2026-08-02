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

    func test_aOneSegmentPickerRendersExactlyOneSegment() async throws {
        for persona in [Persona.review, .publish] {
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
    /// **24 × 24 pt** inside a 240pt column, the three-segment one at
    /// **84 × 24 pt** — so the segmented control hugs its content in both cases
    /// and 28pt-ish per segment is the whole story. Consistent with the 87–145pt
    /// figures already recorded at `BinderSegment.pickerSymbolName`, which is
    /// how we know this measurement is reading the real control.
    func test_theOneSegmentDoesNotStretchTheWholeColumn() async throws {
        let one = try await mount(persona: .review, on: .manuscript)
        let three = try await mount(persona: .plan, on: .canvas)

        XCTAssertEqual(three.segmentCount, 3, "control: Plan is the multi-segment case")
        let oneWidth = one.frame.width
        let threeWidth = three.frame.width
        XCTAssertGreaterThan(oneWidth, 0, "the control must have laid out at all")
        XCTAssertLessThan(oneWidth, 240,
                          "a single segment must not fill the 240pt binder column")
        XCTAssertLessThan(oneWidth, threeWidth,
                          "and it must be narrower than the three-segment picker "
                          + "— measured \(oneWidth)pt against \(threeWidth)pt")
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

    /// **The control.** The same mount at count 2 and count 3, so the count-1
    /// assertions above are reading something that varies rather than a constant
    /// the harness would produce for any input.
    func test_theSegmentCountTracksTheRenderedList() async throws {
        for (persona, selected, expected) in [
            (Persona.review, BinderSegment.manuscript, 1),
            (.author, .manuscript, 2),
            (.plan, .canvas, 3)
        ] as [(Persona, BinderSegment, Int)] {
            let control = try await mount(persona: persona, on: selected)
            XCTAssertEqual(control.segmentCount, expected, "\(persona)")
            XCTAssertEqual(
                control.segmentCount,
                BinderSegmentPicker.visibleSegments(
                    persona: persona, projectType: .novel,
                    hasTrash: false, findActive: false).count,
                "\(persona): what is drawn and what `visibleSegments` says must "
                + "be the same list")
        }
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
    func test_aForcedResearchSelectionRendersAndIsSelectedInAuthor() async throws {
        XCTAssertFalse(Persona.author.binderSegments(for: .novel).contains(.research),
                       "premise: Author no longer offers Research on the left")

        let control = try await mount(persona: .author, on: .research)
        XCTAssertEqual(control.segmentCount, 3,
                       "Manuscript, Palette, and the appended Research")
        XCTAssertEqual(control.selectedSegment, 2,
                       "appended last, and highlighted — a picker with nothing "
                       + "selected over a pane showing research is the defect")
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
        await waitOut(0.4)

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

    private func pumpUntil(deadline: TimeInterval, _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(deadline)
        while Date() < end {
            if condition() { return }
            pump(0.02)
            try? await Task.sleep(for: .milliseconds(20))
        }
        _ = condition()
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
