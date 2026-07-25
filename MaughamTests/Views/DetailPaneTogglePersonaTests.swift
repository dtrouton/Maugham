import SwiftUI
import XCTest
@testable import Maugham

/// `DetailPaneToggle` is generic over its inspector content (`Inspector: View`),
/// so a static member reference has to bind that parameter — Swift cannot infer
/// it from arguments the helpers do not take. `<AnyView>` is an arbitrary
/// witness; `visibleSegments`/`badgeOffset(in:)`/`snappedSelection` are pure
/// and ignore it.
final class DetailPaneTogglePersonaTests: XCTestCase {
    /// The badge is drawn `shift` equal-width segments left of the picker's
    /// trailing edge, so the only assertion worth making is where it LANDS.
    /// Asserting the arithmetic (`shift == 1`) passes just as happily when the
    /// badge sits on the wrong tab, which is the regression that has already
    /// shipped once (the literal 2 survived translation being added).
    private func assertBadgeLandsOnInbox(
        _ segments: [DetailSegment],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let shift = DetailPaneToggle<AnyView>.badgeOffset(in: segments) else {
            return XCTFail("no badge offset for \(segments)", file: file, line: line)
        }
        XCTAssertEqual(segments[segments.count - 1 - shift], .inbox,
                       "badge lands on the wrong segment of \(segments)", file: file, line: line)
    }

    /// This is the sole guard left by the deleted `DetailSegment.allCases`
    /// ordering assertions (it also replaces the character-equivalent copy in
    /// `DetailPaneToggleTasksTests`), so it asserts the landing across every
    /// picker shape rather than one persona's arithmetic.
    func test_badgeLandsOnTheInboxInEveryPickerThatHasOne() {
        for hideOutline in [false, true] {
            for selected in [nil] + DetailSegment.allCases.map({ Optional($0) }) {
                let segments = DetailPaneToggle<AnyView>.visibleSegments(
                    persona: .plan, hideOutline: hideOutline, including: selected)
                assertBadgeLandsOnInbox(segments)
            }
        }
    }

    func test_badgeOffset_isNilWhereThePersonaHasNoInbox() {
        for persona in Persona.allCases where persona != .plan {
            let segments = DetailPaneToggle<AnyView>.visibleSegments(persona: persona, hideOutline: false)
            XCTAssertNil(DetailPaneToggle<AnyView>.badgeOffset(in: segments),
                         "\(persona) has no inbox segment to badge")
        }
    }

    func test_visibleSegments_matchTheRegistry() {
        XCTAssertEqual(DetailPaneToggle<AnyView>.visibleSegments(persona: .author, hideOutline: false),
                       Persona.author.panes)
    }

    func test_visibleSegments_dropOutlineWhenHidden() {
        let segments = DetailPaneToggle<AnyView>.visibleSegments(persona: .author, hideOutline: true)
        XCTAssertFalse(segments.contains(.outline))
        XCTAssertEqual(segments.count, Persona.author.panes.count - 1)
    }

    func test_visibleSegments_areNeverEmpty() {
        for persona in Persona.allCases {
            for hideOutline in [true, false] {
                XCTAssertFalse(
                    DetailPaneToggle<AnyView>.visibleSegments(persona: persona, hideOutline: hideOutline).isEmpty,
                    "\(persona) hideOutline=\(hideOutline) produced an empty picker")
            }
        }
    }

    /// The badge must track inbox's position, not a fixed literal — including
    /// when `hideOutline` shortens the picker on a collection project.
    func test_badgeOffset_survivesTheHideOutlineCollectionCase() {
        let segments = DetailPaneToggle<AnyView>.visibleSegments(persona: .plan, hideOutline: true)
        XCTAssertFalse(segments.contains(.outline))
        assertBadgeLandsOnInbox(segments)
    }

    // MARK: - The picker always shows its active segment

    /// The nine ⌘⌥-letter pane shortcuts fire in every persona, so a writer in
    /// Author can land on Annotations. The pane content is right; without this
    /// the picker rendered with nothing selected.
    func test_visibleSegments_includeASelectionThisPersonaDoesNotRegister() {
        let segments = DetailPaneToggle<AnyView>.visibleSegments(
            persona: .author, hideOutline: false, including: .annotations)
        XCTAssertTrue(segments.contains(.annotations))
        // Appended, not woven into registry order — the persona's own ordering
        // stays put and the addition reads as transient.
        XCTAssertEqual(Array(segments.dropLast()), Persona.author.panes)
        XCTAssertEqual(segments.last, .annotations)
    }

    /// The translation-review force-set (`ProjectWindow` sets
    /// `detailSegment = .translation`) has the same shape.
    func test_visibleSegments_includeTranslationWhenForcedOutsideItsPersonas() {
        let segments = DetailPaneToggle<AnyView>.visibleSegments(
            persona: .author, hideOutline: false, including: .translation)
        XCTAssertTrue(segments.contains(.translation))
    }

    func test_visibleSegments_doNotDuplicateASelectionThePersonaRegisters() {
        let segments = DetailPaneToggle<AnyView>.visibleSegments(
            persona: .author, hideOutline: false, including: .tasks)
        XCTAssertEqual(segments, Persona.author.panes)
        XCTAssertEqual(segments.filter { $0 == .tasks }.count, 1)
    }

    /// The whole point of deriving the offset: an appended out-of-persona
    /// segment lengthens the picker, and a badge computed from the shorter
    /// list would land one tab to the right of the inbox.
    func test_badgeOffset_staysOnTheInboxWhenAnOutOfPersonaSegmentIsAppended() {
        let segments = DetailPaneToggle<AnyView>.visibleSegments(
            persona: .plan, hideOutline: false, including: .annotations)
        // Plan gained one segment beyond its registry list.
        XCTAssertEqual(segments.count, Persona.plan.panes.count + 1)
        assertBadgeLandsOnInbox(segments)
    }

    // MARK: - Snap-back: the picker never renders with nothing selected

    /// ⌘⌥O on a collection project sets `.outline`, which `visibleSegments`
    /// refuses to append (its content falls through to the inspector, so the
    /// tab would lie). Left alone that is a picker with no highlighted
    /// segment — the state the `including:` append exists to prevent.
    func test_snappedSelection_pullsOutlineBackWhenTheProjectHidesIt() {
        let segments = DetailPaneToggle<AnyView>.visibleSegments(
            persona: .plan, hideOutline: true, including: .outline)
        let snapped = DetailPaneToggle<AnyView>.snappedSelection(
            .outline, in: segments, fallback: Persona.plan.defaultPane)
        XCTAssertNotEqual(snapped, .outline)
        XCTAssertTrue(segments.contains(snapped), "snapped onto a segment the picker does not show")
        XCTAssertEqual(snapped, segments.first)
    }

    func test_snappedSelection_leavesEveryOtherSelectionAlone() {
        // Personas are lenses, not gates: an out-of-persona segment reached by
        // shortcut is appended and must stay selected. Only the hidden outline
        // is ever pulled back.
        for persona in Persona.allCases {
            for hideOutline in [false, true] {
                for proposed in DetailSegment.allCases {
                    let segments = DetailPaneToggle<AnyView>.visibleSegments(
                        persona: persona, hideOutline: hideOutline, including: proposed)
                    let snapped = DetailPaneToggle<AnyView>.snappedSelection(
                        proposed, in: segments, fallback: persona.defaultPane)
                    XCTAssertTrue(segments.contains(snapped),
                                  "\(persona)/\(proposed) hideOutline=\(hideOutline) snapped off-picker")
                    if hideOutline && proposed == .outline {
                        XCTAssertNotEqual(snapped, proposed)
                    } else {
                        XCTAssertEqual(snapped, proposed,
                                       "\(persona) should keep \(proposed) selected")
                    }
                }
            }
        }
    }

    // MARK: - The mount-time snap keeps an out-of-persona pane

    /// `DetailPaneToggle` mounts conditionally on `showInspector`, so a
    /// `⌘⌥`-letter shortcut that REVEALS a hidden column
    /// (`showInspector = true` then `detailSegment = seg`) mounts the picker
    /// fresh with the requested segment already in place: `.onChange(of:
    /// segment)` cannot fire, but `.onAppear` does.
    ///
    /// `.onAppear` therefore has to snap against the selection-carrying list
    /// (`visibleSegments(including:)`) — the shape asserted here. Snapping
    /// against the persona's BARE registry list instead, which is what
    /// `coerceSegmentIntoView(of:)` does and what `.onAppear` used to call,
    /// throws the requested pane away: the second half of this test is the
    /// failing behaviour, pinned so the two call sites cannot be conflated
    /// again (whole-branch review, Critical 1).
    func test_mountSelection_keepsAnOutOfRegistrySegment() {
        // Author has no Annotations pane; ⌘⌥A with the column closed lands here.
        let selected = DetailSegment.annotations
        XCTAssertFalse(Persona.author.panes.contains(selected))

        XCTAssertEqual(
            DetailPaneToggle<AnyView>.mountSelection(
                selected, persona: .author, hideOutline: false),
            selected,
            "the mount-time snap must keep the pane the writer just asked for")

        // The list `mountSelection` must NOT consult — proof the distinction
        // bites, and what the old `.onAppear` coercion produced.
        let bare = DetailPaneToggle<AnyView>.visibleSegments(
            persona: .author, hideOutline: false)
        XCTAssertEqual(
            DetailPaneToggle<AnyView>.snappedSelection(
                selected, in: bare, fallback: Persona.author.defaultPane),
            Persona.author.defaultPane,
            "the bare registry list is the one that eats the selection")
    }

    /// Every persona × every pane shortcut: revealing a hidden column must
    /// land on the requested pane. `.outline` on a collection is the sole
    /// exception — its content falls through to the inspector, so a tab would
    /// lie, and the snap pulls it back. This is ADR 0025 §3's claim that
    /// "every pane shortcut now reveals a hidden column before selecting its
    /// pane" stated as a test.
    func test_mountSelection_landsOnTheRequestedPaneInEveryPersona() {
        for persona in Persona.allCases {
            for hideOutline in [false, true] {
                for requested in DetailSegment.allCases {
                    let landed = DetailPaneToggle<AnyView>.mountSelection(
                        requested, persona: persona, hideOutline: hideOutline)
                    if hideOutline && requested == .outline {
                        XCTAssertNotEqual(landed, requested)
                    } else {
                        XCTAssertEqual(landed, requested,
                                       "\(persona) dropped \(requested) on reveal")
                    }
                }
            }
        }
    }

    /// `hideOutline` still wins over the selection: a collection project has
    /// no outline pane, and appending it would render a tab whose content
    /// falls through to the inspector.
    func test_visibleSegments_doNotAppendOutlineWhenItIsHidden() {
        let segments = DetailPaneToggle<AnyView>.visibleSegments(
            persona: .publish, hideOutline: true, including: .outline)
        XCTAssertFalse(segments.contains(.outline))
    }
}
