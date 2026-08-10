import SwiftUI
import XCTest
@testable import Maugham

/// `DetailPaneToggle` is generic over its inspector content (`Inspector: View`),
/// so a static member reference has to bind that parameter — Swift cannot infer
/// it from arguments the helpers do not take. `<AnyView>` is an arbitrary
/// witness; `visibleSegments`/`badgeOffset(of:in:)`/`snappedSelection` are pure
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
        guard let shift = DetailPaneToggle<AnyView>.badgeOffset(of: .inbox, in: segments) else {
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
        for selected in [nil] + DetailSegment.allCases.map({ Optional($0) }) {
            let segments = DetailPaneToggle<AnyView>.visibleSegments(
                persona: .plan, including: selected)
            assertBadgeLandsOnInbox(segments)
        }
    }

    func test_badgeOffset_isNilWhereThePersonaHasNoInbox() {
        for persona in Persona.allCases where persona != .plan {
            let segments = DetailPaneToggle<AnyView>.visibleSegments(persona: persona)
            XCTAssertNil(DetailPaneToggle<AnyView>.badgeOffset(of: .inbox, in: segments),
                         "\(persona) has no inbox segment to badge")
        }
    }

    func test_visibleSegments_matchTheRegistry() {
        XCTAssertEqual(DetailPaneToggle<AnyView>.visibleSegments(persona: .author),
                       Persona.author.panes)
    }

    func test_visibleSegments_areNeverEmpty() {
        for persona in Persona.allCases {
            XCTAssertFalse(
                DetailPaneToggle<AnyView>.visibleSegments(persona: persona).isEmpty,
                "\(persona) produced an empty picker")
        }
    }

    // MARK: - The picker always shows its active segment

    /// Every ⌘⌥-letter pane shortcut fires in every persona — one per
    /// `DetailSegment` case, which is the only place that set is counted — so a
    /// writer in Author can land on Annotations. The pane content is right;
    /// without this the picker rendered with nothing selected.
    func test_visibleSegments_includeASelectionThisPersonaDoesNotRegister() {
        let segments = DetailPaneToggle<AnyView>.visibleSegments(
            persona: .author, including: .annotations)
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
            persona: .author, including: .translation)
        XCTAssertTrue(segments.contains(.translation))
    }

    func test_visibleSegments_doNotDuplicateASelectionThePersonaRegisters() {
        let segments = DetailPaneToggle<AnyView>.visibleSegments(
            persona: .author, including: .tasks)
        XCTAssertEqual(segments, Persona.author.panes)
        XCTAssertEqual(segments.filter { $0 == .tasks }.count, 1)
    }

    /// The whole point of deriving the offset: an appended out-of-persona
    /// segment lengthens the picker, and a badge computed from the shorter
    /// list would land one tab to the right of the inbox.
    func test_badgeOffset_staysOnTheInboxWhenAnOutOfPersonaSegmentIsAppended() {
        let segments = DetailPaneToggle<AnyView>.visibleSegments(
            persona: .plan, including: .annotations)
        // Plan gained one segment beyond its registry list.
        XCTAssertEqual(segments.count, Persona.plan.panes.count + 1)
        assertBadgeLandsOnInbox(segments)
    }

    // MARK: - Snap-back: the picker never renders with nothing selected

    /// Personas are lenses, not gates: an out-of-persona segment reached by
    /// shortcut is appended by `visibleSegments(including:)` and must stay
    /// selected. The one refusal this ever had — `.outline` on a collection
    /// project — died with the case (stage 3a Task 6), so every proposed
    /// segment now round-trips through `snappedSelection` unchanged.
    func test_snappedSelection_leavesEveryOtherSelectionAlone() {
        for persona in Persona.allCases {
            for proposed in DetailSegment.allCases {
                let segments = DetailPaneToggle<AnyView>.visibleSegments(
                    persona: persona, including: proposed)
                let snapped = DetailPaneToggle<AnyView>.snappedSelection(
                    proposed, in: segments, fallback: persona.defaultPane)
                XCTAssertTrue(segments.contains(snapped),
                              "\(persona)/\(proposed) snapped off-picker")
                XCTAssertEqual(snapped, proposed,
                               "\(persona) should keep \(proposed) selected")
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
            DetailPaneToggle<AnyView>.mountSelection(selected, persona: .author),
            selected,
            "the mount-time snap must keep the pane the writer just asked for")

        // The list `mountSelection` must NOT consult — proof the distinction
        // bites, and what the old `.onAppear` coercion produced.
        let bare = DetailPaneToggle<AnyView>.visibleSegments(persona: .author)
        XCTAssertEqual(
            DetailPaneToggle<AnyView>.snappedSelection(
                selected, in: bare, fallback: Persona.author.defaultPane),
            Persona.author.defaultPane,
            "the bare registry list is the one that eats the selection")
    }

    /// Every persona × every pane shortcut: revealing a hidden column must
    /// land on the requested pane. This is ADR 0025 §3's claim that "every
    /// pane shortcut now reveals a hidden column before selecting its pane"
    /// stated as a test. The one exception this used to carry — `.outline` on
    /// a collection, whose content fell through to the inspector — died with
    /// the case (stage 3a Task 6): there is no longer any segment whose
    /// content can fall through, so every request lands exactly.
    func test_mountSelection_landsOnTheRequestedPaneInEveryPersona() {
        for persona in Persona.allCases {
            for requested in DetailSegment.allCases {
                let landed = DetailPaneToggle<AnyView>.mountSelection(
                    requested, persona: persona)
                XCTAssertEqual(landed, requested,
                               "\(persona) dropped \(requested) on reveal")
            }
        }
    }

    // MARK: - Retired: the registry-less segment

    // `test_aPaneRegisteredInNoPersonaIsStillReachable` and
    // `test_visibleSegments_doNotAppendOutlineWhenItIsHidden` are gone rather
    // than reworked. Both pinned `.outline`'s specific status as the one
    // `DetailSegment` case registered in no persona at all — reachable only
    // via `mountSelection`/`visibleSegments(including:)`'s append, never via
    // `Persona.panes`. Stage 3a Task 6 deleted the case outright rather than
    // leaving it registry-less, and `PersonaPaneRegistryTests
    // .test_everyDetailSegmentIsRegisteredSomewhere` now pins the flat
    // replacement: every surviving case has a persona. The first test's own
    // body already said what to do here — "no segment is unregistered, so
    // this test is vacuous — delete it" — which is exactly the state Task 6
    // brought about on purpose, not a registry silently re-adopting a pane.
    // The append mechanism itself (an out-of-persona selection still reaching
    // the picker) is not retired — see
    // `test_visibleSegments_includeASelectionThisPersonaDoesNotRegister`,
    // `test_visibleSegments_includeTranslationWhenForcedOutsideItsPersonas`
    // and `PersonaPaneRegistryTests.test_forcedEntryReachesAPersonaThatDoesNotRegisterIt`.
}
