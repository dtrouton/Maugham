import XCTest
@testable import Maugham

final class PersonaPaneRegistryTests: XCTestCase {
    func test_everyPersona_offersAtLeastTwoPanes() {
        // A one-pane picker reads as broken chrome rather than a choice.
        for persona in Persona.allCases {
            XCTAssertGreaterThanOrEqual(persona.panes.count, 2,
                                        "\(persona) offers \(persona.panes.count) pane(s)")
        }
    }

    func test_everyPersona_listsEachPaneAtMostOnce() {
        for persona in Persona.allCases {
            XCTAssertEqual(Set(persona.panes).count, persona.panes.count,
                           "\(persona) lists a duplicate pane")
        }
    }

    func test_everyDetailSegment_appearsInAtLeastOnePersona() {
        // Guards the failure mode where a new pane is added to DetailSegment
        // but never registered, making it permanently unreachable.
        let registered = Set(Persona.allCases.flatMap(\.panes))
        for segment in DetailSegment.allCases {
            XCTAssertTrue(registered.contains(segment),
                          "\(segment) is registered in no persona and is unreachable")
        }
    }

    func test_defaultPane_isTheFirstRegisteredPane() {
        for persona in Persona.allCases {
            XCTAssertEqual(persona.defaultPane, persona.panes.first)
        }
    }

    func test_authorPersona_excludesAnnotations() {
        // The two-loop separation from the design: adjudicating durable notes
        // is a review activity. Diagnostics (M1B+1) serve the fast loop.
        XCTAssertFalse(Persona.author.panes.contains(.annotations))
    }

    func test_reviewPersona_leadsWithAnnotations() {
        XCTAssertEqual(Persona.review.defaultPane, .annotations)
    }

    /// Both were ○ in the design's pane × persona matrix (§6.3) and both were
    /// dropped when the registry was first written. Translation is the
    /// consequential one: reviewing a translated edition is a review activity,
    /// and `ProjectWindow` force-sets `detailSegment = .translation` when the
    /// writer enters translation review.
    func test_reviewPersona_offersTranslationAndPalette() {
        XCTAssertTrue(Persona.review.panes.contains(.translation))
        XCTAssertTrue(Persona.review.panes.contains(.palette))
    }

    func test_inboxIsPlanningOnly() {
        // Phone captures are raw planning material. They previously sat
        // between Tasks and Palette, which is why the segment needed an
        // unread badge to be discoverable at all.
        for persona in Persona.allCases where persona != .plan {
            XCTAssertFalse(persona.panes.contains(.inbox), "\(persona) should not offer the inbox")
        }
        XCTAssertTrue(Persona.plan.panes.contains(.inbox))
    }

    func test_coerce_keepsAPaneThePersonaOffers() {
        XCTAssertEqual(Persona.author.coerce(.tasks), .tasks)
    }

    func test_coerce_redirectsAPaneThePersonaDoesNotOffer() {
        XCTAssertEqual(Persona.author.coerce(.annotations), Persona.author.defaultPane)
    }
}
