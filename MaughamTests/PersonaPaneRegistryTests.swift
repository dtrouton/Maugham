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

    /// Panes registered in no persona at all. The persona shell's slice 1
    /// demoted `.outline`: the tree shows structure and `OutlinePane` is
    /// read-only, so it cannot be the structure surface Plan needs
    /// (`docs/superpowers/specs/2026-08-01-persona-shell-workflow-design.md`
    /// §5).
    ///
    /// This list REPLACES `test_everyDetailSegment_appearsInAtLeastOnePersona`,
    /// deleted by that slice. That test asserted every segment is registered
    /// somewhere, and its failure message called an unregistered one
    /// "unreachable" — **the claim was false**, and it was the claim, not the
    /// arithmetic, that made the test wrong. Verified 2026-08-01:
    /// `MaughamApp.swift:222-223` binds ⌘⌥O unconditionally and the key-window
    /// handler sets the segment with no registry check;
    /// `DetailPaneToggle.visibleSegments(including:)` appends an unregistered
    /// selection ("Personas are lenses, not gates"); and `segmentContent`
    /// renders `OutlinePane` on `hideOutline` alone. Spec §8 says the same
    /// normatively. Reachability is pinned as a property rather than assumed:
    /// `DetailPaneTogglePersonaTests.test_aPaneRegisteredInNoPersonaIsStillReachable`
    /// drives it through the toggle's own helpers.
    private static let deliberatelyUnregistered: Set<DetailSegment> = [.outline]

    func test_everyDetailSegmentIsRegisteredOrDeliberatelyUnregistered() {
        // The half of the deleted test that was true: a new pane added to
        // DetailSegment and then forgotten is a real failure mode. It is now a
        // census — a segment is registered somewhere, or it is named above
        // with a reason. Silence is what fails.
        let registered = Set(Persona.allCases.flatMap(\.panes))
        for segment in DetailSegment.allCases {
            XCTAssertTrue(registered.contains(segment)
                            || Self.deliberatelyUnregistered.contains(segment),
                          "\(segment) is in no persona's registry and is not listed in "
                          + "deliberatelyUnregistered. Register it, or list it there with "
                          + "the reason it is summonable-only.")
        }
    }

    /// The control that keeps the census above falsifiable: a segment listed as
    /// unregistered must actually BE unregistered, so the list cannot rot into
    /// a blanket exemption that swallows a genuine oversight.
    func test_nothingInTheUnregisteredListIsActuallyRegistered() {
        let registered = Set(Persona.allCases.flatMap(\.panes))
        for segment in Self.deliberatelyUnregistered {
            XCTAssertFalse(registered.contains(segment),
                           "\(segment) is registered after all — take it out of "
                           + "deliberatelyUnregistered")
        }
        XCTAssertFalse(Self.deliberatelyUnregistered.isEmpty,
                       "the list is empty, so both tests above are vacuous")
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

    // MARK: - The whole matrix, not a row at a time

    /// The design's pane × persona matrix, transcribed. Both `●` (primary) and
    /// `○` (available) mean the segment belongs to that persona; `—` means
    /// absent. Only segments that have a `DetailSegment` case today —
    /// Diagnostics, References and Editions belong to later milestones and are
    /// listed as reserved in `Persona.panes`. Intent and Visual language joined
    /// in M1A.
    ///
    /// **Two documents make this table, and the transcription's authority moved
    /// with the persona shell.** The base is §6.3 of
    /// `docs/superpowers/specs/2026-07-25-mode-based-ux-redesign-design.md`;
    /// §5 of `docs/superpowers/specs/2026-08-01-persona-shell-workflow-design.md`
    /// is an amendment in force to it, and where they disagree the amendment
    /// wins. Applied below, from the amendment's "Leaving, by persona" list
    /// (which is the delta the amendment states normatively — its three-column
    /// table summarises and drops cells the delta keeps, e.g. Review's visual
    /// language and Plan's palette, so the delta is what is transcribed):
    ///
    /// - `.outline` leaves all four.
    /// - `.translation` and `.intent` leave Publish.
    /// - `.history` joins Author.
    /// - `.tasks` leaves Plan, and `.inspector` dissolves out of every persona
    ///   (§5.1) — both still owed, see `notYetDelivered`.
    ///
    /// Editing this table without re-citing it leaves the test asserting a
    /// matrix no document contains.
    private static let designMatrix: [Persona: Set<DetailSegment>] = [
        .plan: [.research, .inbox, .palette, .intent, .visualLanguage],
        .author: [.research, .tasks, .palette, .intent, .history],
        .review: [.history, .tasks, .palette, .translation,
                  .annotations, .intent, .visualLanguage],
        .publish: [.visualLanguage]
    ]

    /// Departures the amendment requires that slice 1 does not deliver. This is
    /// the ledger the `Persona.panes` comment points at rather than restating.
    /// It is deliberately NOT merged into `documentedDeviations`: a deviation
    /// is a decision to differ from the design, this is a decision the design
    /// already made and a later slice carries out. Merging them would lose
    /// which of the two a reader is looking at.
    ///
    /// - Plan's `.tasks`: §5 says Plan loses it. §6 assigns it to no slice, so
    ///   it goes when Plan's column is re-cut, not here.
    /// - `.inspector`: §5.1 dissolves it into per-persona sections — slice 4.
    ///   Publish's copy is a `documentedDeviation` instead, because there it is
    ///   load-bearing rather than pending; see its case in `Persona.panes`.
    private static let notYetDelivered: [Persona: Set<DetailSegment>] = [
        .plan: [.tasks, .inspector],
        .author: [.inspector],
        .review: [.inspector]
    ]

    /// Deviations the registry takes on purpose, each argued at its case in
    /// `Persona.panes`. Listing them here is what makes the matrix test able to
    /// fail on an oversight: anything outside matrix ∪ deviations ∪ pending is
    /// a pane nobody decided to add.
    private static let documentedDeviations: [Persona: Set<DetailSegment>] = [
        // `InspectorPublishSection` is the only UI in the app for per-piece
        // publish config, so removing it before slice 4 gives Publish its own
        // pane deletes the writer's table-of-contents control (§5.1). It also
        // holds Publish on the two-pane floor asserted above.
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
            let allowed = expected
                .union(Self.documentedDeviations[persona] ?? [])
                .union(Self.notYetDelivered[persona] ?? [])
            let actual = Set(persona.panes)

            for segment in expected.subtracting(actual) {
                XCTFail("\(persona) is missing \(segment), which the design marks ● or ○")
            }
            for segment in actual.subtracting(allowed) {
                XCTFail("""
                    \(persona) offers \(segment), which the design marks —. If that is \
                    deliberate, argue it at the case in Persona.panes and add it \
                    to documentedDeviations; if a later slice removes it, add it \
                    to notYetDelivered.
                    """)
            }
        }
    }

    /// Every pane pending removal must still be registered — otherwise the
    /// entry is stale and the next reader believes a departure is owed that has
    /// already happened.
    func test_nothingInNotYetDeliveredHasAlreadyLeft() {
        for (persona, pending) in Self.notYetDelivered {
            for segment in pending {
                XCTAssertTrue(persona.panes.contains(segment),
                              "\(persona) no longer offers \(segment) — its departure "
                              + "shipped, so take it out of notYetDelivered")
            }
        }
    }

    /// The reserved segments have no case yet, so the matrix above cannot
    /// mention them. This pins the assumption: if a later milestone adds one,
    /// this test fails and `designMatrix` must gain its row.
    ///
    /// `deliberatelyUnregistered` counts as a mention: `.outline` is in no
    /// persona's row because the amendment took it out of all four, and that is
    /// a decision recorded rather than a segment forgotten.
    func test_designMatrixCoversEveryDetailSegmentThatExists() {
        let mentioned = Set(Self.designMatrix.values.flatMap { $0 })
            .union(Self.documentedDeviations.values.flatMap { $0 })
            .union(Self.notYetDelivered.values.flatMap { $0 })
            .union(Self.deliberatelyUnregistered)
        for segment in DetailSegment.allCases {
            XCTAssertTrue(mentioned.contains(segment),
                          "\(segment) exists but has no row in the transcribed matrix")
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
