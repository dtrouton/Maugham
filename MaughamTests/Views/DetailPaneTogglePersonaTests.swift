import SwiftUI
import XCTest
@testable import Maugham

/// `DetailPaneToggle` is generic over its inspector content (`Inspector: View`),
/// so a static member reference has to bind that parameter — Swift cannot infer
/// it from arguments the helpers do not take. `<AnyView>` is an arbitrary
/// witness; `visibleSegments`/`badgeOffsetSegments` are pure and ignore it.
final class DetailPaneTogglePersonaTests: XCTestCase {
    func test_badgeOffset_isComputedFromTheInboxPositionInThisPersona() {
        // Plan offers [research, outline, palette, inbox, inspector] —
        // inbox is second from the end, so the badge shifts by 1 segment.
        XCTAssertEqual(DetailPaneToggle<AnyView>.badgeOffsetSegments(persona: .plan), 1)
    }

    func test_badgeOffset_isNilWhereThePersonaHasNoInbox() {
        for persona in Persona.allCases where persona != .plan {
            XCTAssertNil(DetailPaneToggle<AnyView>.badgeOffsetSegments(persona: persona),
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
        // Plan minus outline is [research, palette, inbox, inspector] —
        // inbox is still second from the end.
        XCTAssertEqual(DetailPaneToggle<AnyView>.badgeOffsetSegments(persona: .plan, hideOutline: true), 1)
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
        let shift = DetailPaneToggle<AnyView>.badgeOffsetSegments(
            persona: .plan, hideOutline: false, including: .annotations)
        // Plan gained a sixth segment, so inbox is now third from the end.
        XCTAssertEqual(segments.count, Persona.plan.panes.count + 1)
        XCTAssertEqual(shift, 2)
        // Assert the landing, not the arithmetic: shifting `shift` segments
        // left from the trailing edge must arrive at the inbox.
        XCTAssertEqual(segments[segments.count - 1 - (shift ?? -1)], .inbox)
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
