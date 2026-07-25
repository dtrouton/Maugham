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

    // MARK: - The whole §6.3 matrix, not a row at a time

    /// `docs/superpowers/specs/2026-07-25-mode-based-ux-redesign-design.md`
    /// §6.3, transcribed. Both `●` (primary) and `○` (available) mean the
    /// segment belongs to that persona; `—` means absent. Only segments that
    /// have a `DetailSegment` case today — Diagnostics, References, Intent,
    /// Visual language and Editions belong to later milestones and are listed
    /// as reserved in `Persona.panes`.
    private static let designMatrix: [Persona: Set<DetailSegment>] = [
        .plan: [.inspector, .research, .outline, .tasks, .inbox, .palette],
        .author: [.inspector, .research, .outline, .tasks, .palette],
        .review: [.inspector, .outline, .history, .tasks, .palette, .translation, .annotations],
        .publish: [.translation]
    ]

    /// Deviations from §6.3 that the registry takes on purpose, each argued at
    /// its case in `Persona.panes`. Listing them here is what makes the matrix
    /// test able to fail on an oversight: anything outside matrix ∪ deviations
    /// is a pane nobody decided to add.
    private static let documentedDeviations: [Persona: Set<DetailSegment>] = [
        // Publish would otherwise be a one-button picker until M1D.
        .publish: [.inspector]
    ]

    /// Asserts every persona against the whole table in one pass. Row-at-a-time
    /// spot checks let the same defect through twice: Review lost `.translation`
    /// and `.palette` when the registry was written, and Plan lost `.tasks` in
    /// the commit that fixed Review. A per-row assertion can only ever prove
    /// its own row.
    func test_everyPersona_matchesTheDesignMatrix() {
        for persona in Persona.allCases {
            let expected = Self.designMatrix[persona] ?? []
            let allowed = expected.union(Self.documentedDeviations[persona] ?? [])
            let actual = Set(persona.panes)

            for segment in expected.subtracting(actual) {
                XCTFail("\(persona) is missing \(segment), which §6.3 marks ● or ○")
            }
            for segment in actual.subtracting(allowed) {
                XCTFail("""
                    \(persona) offers \(segment), which §6.3 marks —. If that is \
                    deliberate, argue it at the case in Persona.panes and add it \
                    to documentedDeviations.
                    """)
            }
        }
    }

    /// The reserved segments have no case yet, so the matrix above cannot
    /// mention them. This pins the assumption: if a later milestone adds one,
    /// this test fails and `designMatrix` must gain its row.
    func test_designMatrixCoversEveryDetailSegmentThatExists() {
        let mentioned = Set(Self.designMatrix.values.flatMap { $0 })
            .union(Self.documentedDeviations.values.flatMap { $0 })
        for segment in DetailSegment.allCases {
            XCTAssertTrue(mentioned.contains(segment),
                          "\(segment) exists but has no row in the transcribed §6.3 matrix")
        }
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
