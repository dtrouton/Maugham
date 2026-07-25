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
}
