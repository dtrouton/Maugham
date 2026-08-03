import XCTest
@testable import Maugham

final class PersonaPaneRegistryTests: XCTestCase {
    func test_everyPersona_offersAtLeastTwoPanes() {
        // A one-pane picker reads as broken chrome rather than a choice.
        //
        // **Nothing sits on this floor any more.** Publish did, exactly, from
        // slice 1 until §5.0's re-cut — which is why the floor was cited as
        // half the reason Publish kept `.inspector`. It carries five panes now,
        // and the real argument for that cell was always
        // `InspectorPublishSection` rather than the count; see the `.publish`
        // case in `Persona.panes`. Left in place as a floor, not as a reason.
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

    // MARK: - One order, four subsets

    /// **The canonical right-column order**, transcribed once. §5.0 of
    /// `docs/superpowers/specs/2026-08-01-persona-shell-workflow-design.md`
    /// (2026-08-03), which supersedes §5's per-persona lists for the right
    /// column. Denver: *"it'll be confusing if I am always hunting for the
    /// right option in different modes, so the order should be one set and
    /// things just disappear or appear in it, and we have some common
    /// anchors."*
    ///
    /// Three anchors: **Tasks** divides what you are working *with* from what
    /// is flowing *through*; **History** and **Inspector** close the row,
    /// Inspector outermost.
    ///
    /// **Inspector last is load-bearing, not tidiness.** `defaultPane` is
    /// `panes.first`, so each persona's default falls out of membership plus
    /// this order and nothing picks it. Inspector first — the shape an earlier
    /// draft of §5.0 had — would land every persona on Inspector and force
    /// `panes` to become an order plus a separate default: two values that can
    /// disagree about where a persona opens.
    ///
    /// Deliberately not `private`, unlike the ledgers below: a later test that
    /// needs this order should reuse it rather than transcribe it a second
    /// time, which is the whole argument for having one.
    static let canonicalPaneOrder: [DetailSegment] = [
        .annotations, .inbox, .research, .palette, .intent,
        .visualLanguage, .tasks, .translation, .history, .inspector
    ]

    /// **The order guard, and it is the first assertion of pane ORDER this
    /// suite has ever carried.** The right-column audit of 2026-08-03 found
    /// that order was asserted nowhere: every array-equality in
    /// `DetailPaneTogglePersonaTests` compares against `Persona.<x>.panes`
    /// itself and so re-derives under any permutation, and the only real
    /// constraint was on first elements. *"A reorder that keeps every first
    /// element would pass the whole suite while changing the picker for every
    /// writer."* `test_theOrderGuardCatchesAReorderThatKeepsEveryFirstElement`
    /// below is that reorder, planted.
    ///
    /// **Expressed as a derivation, never as four expected arrays.** A
    /// per-persona literal would have to be edited in the same commit as any
    /// membership change, which is exactly the edit that reintroduces drift —
    /// and four transcriptions of one order is four chances to mistype it. The
    /// persona's own members come from `panes`, so this test asserts one
    /// property and one only: **`panes` is a subsequence of the canonical
    /// order.** Membership is `test_everyPersona_matchesTheDesignMatrix`'s job
    /// and is not restated here.
    func test_everyPersonasPanesAreTheCanonicalOrderFilteredToItsMembers() {
        for persona in Persona.allCases {
            let members = Set(persona.panes)
            XCTAssertEqual(persona.panes,
                           Self.canonicalPaneOrder.filter(members.contains),
                           "\(persona)'s picker is not the canonical order filtered to "
                           + "its own members. A persona case in Persona.panes chooses "
                           + "MEMBERSHIP; the sequence is canonicalPaneOrder's and is "
                           + "the same in all four.")
        }
    }

    /// The control that keeps the guard above falsifiable from the other side.
    /// The expectation is built by filtering `canonicalPaneOrder`, so a segment
    /// **missing** from that order is silently dropped from the expectation —
    /// and the guard would then fail with a length mismatch whose message
    /// blames the persona rather than the order. This says which it is, and it
    /// is also the census a new `DetailSegment` has to answer: give it a place
    /// in the order, or list it in `deliberatelyUnregistered`.
    func test_theCanonicalOrderPlacesEveryPaneThatIsRegisteredAnywhere() {
        XCTAssertEqual(Set(Self.canonicalPaneOrder).count, Self.canonicalPaneOrder.count,
                       "canonicalPaneOrder lists a segment twice")
        XCTAssertFalse(Self.canonicalPaneOrder.isEmpty,
                       "the order is empty, so the guard above is vacuous")
        for segment in DetailSegment.allCases {
            XCTAssertTrue(Self.canonicalPaneOrder.contains(segment)
                            || Self.deliberatelyUnregistered.contains(segment),
                          "\(segment) has no place in the canonical right-column order "
                          + "and is not listed in deliberatelyUnregistered")
        }
    }

    /// **The planted offender.** Author's real panes, with Intent moved up two
    /// places — a permutation built to survive every other test in this suite:
    /// same members (so the design-matrix test passes), same first element (so
    /// `test_defaultPane_isTheFirstRegisteredPane`,
    /// `test_reviewPersona_leadsWithAnnotations`, `PersonaModifierTests` and
    /// every derived array-equality in `DetailPaneTogglePersonaTests` pass).
    /// Only the guard above sees it. A plant that does not fire is the finding.
    func test_theOrderGuardCatchesAReorderThatKeepsEveryFirstElement() {
        let offender: [DetailSegment] = [.research, .intent, .palette,
                                         .tasks, .history, .inspector]

        // The plant is honest: a permutation of Author's own panes, not a
        // membership change wearing a permutation's clothes.
        XCTAssertEqual(Set(offender), Set(Persona.author.panes),
                       "the plant must differ from Author's panes only in ORDER — "
                       + "update it alongside Author's membership")
        XCTAssertNotEqual(offender, Persona.author.panes,
                          "the plant IS Author's order, so it plants nothing")
        XCTAssertEqual(offender.first, Persona.author.panes.first,
                       "the plant must keep the first element, or an existing test "
                       + "catches it and it proves nothing about order")

        // The guard's own predicate, run against the plant.
        XCTAssertNotEqual(offender,
                          Self.canonicalPaneOrder.filter(Set(offender).contains),
                          "the guard accepted a permutation — it is asserting "
                          + "membership, not order")
    }

    func test_authorPersona_excludesAnnotations() {
        // The two-loop separation from the design: adjudicating durable notes
        // is a review activity. Diagnostics (M1B+1) serve the fast loop.
        XCTAssertFalse(Persona.author.panes.contains(.annotations))
    }

    /// The suite's oldest order constraint, and until 2026-08-03 its only one.
    /// It now has a sibling —
    /// `test_everyPersonasPanesAreTheCanonicalOrderFilteredToItsMembers` — and
    /// keeping both is deliberate: the sibling says Review's panes follow the
    /// shared order, this says Review must *lead* with adjudication. A future
    /// canonical order that moved Annotations off the front would satisfy the
    /// sibling and fail here, which is the argument that would need to be had.
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
    /// **Three documents make this table, each later than the last, and the
    /// transcription's authority moved again on 2026-08-03.** The base is §6.3
    /// of `docs/superpowers/specs/2026-07-25-mode-based-ux-redesign-design.md`;
    /// §5 of `docs/superpowers/specs/2026-08-01-persona-shell-workflow-design.md`
    /// amends it; **§5.0 of that same document supersedes §5's per-persona
    /// lists for the right column**, and its four-row table is what is
    /// transcribed below. §5's own "Leaving, by persona" delta — which the last
    /// transcription used, because §5's three-column table dropped cells the
    /// delta kept — is no longer the authority for this registry.
    ///
    /// §5.0's rows, which are also the canonical order filtered four ways:
    ///
    /// - **Plan** — Inbox · Tasks · History · Inspector. It loses Research,
    ///   Palette, Intent and Visual Language: Plan authors all four, and
    ///   authoring is the left column's.
    /// - **Author** — Research · Palette · Intent · Tasks · History ·
    ///   Inspector. Membership unchanged; only the order moved.
    /// - **Review** — Annotations · Intent · Tasks · History · Inspector. It
    ///   loses Palette, Visual Language and Translation.
    /// - **Publish** — Visual Language · Tasks · Translation · History ·
    ///   Inspector. Translation arrives, reversing §5's move of it to Review.
    ///
    /// Two cells changed CATEGORY rather than membership, and both are worth
    /// naming because a reader of the previous version will look for them:
    /// **Plan's `.tasks` came off `notYetDelivered`** (§5 removed it, §5.0 is
    /// later and gives it back, so it is design now), and **Publish's
    /// `.inspector` came out of `documentedDeviations`** (§5.0 gives Inspector
    /// to all four, so it is no longer a deviation from anything — see
    /// `notYetDelivered`).
    ///
    /// Editing this table without re-citing it leaves the test asserting a
    /// matrix no document contains.
    private static let designMatrix: [Persona: Set<DetailSegment>] = [
        .plan: [.inbox, .tasks, .history],
        .author: [.research, .palette, .intent, .tasks, .history],
        .review: [.annotations, .intent, .tasks, .history],
        .publish: [.visualLanguage, .tasks, .translation, .history]
    ]

    /// Departures the design requires that this re-cut does not deliver. This
    /// is the ledger the `Persona.panes` comment points at rather than
    /// restating. It is deliberately NOT merged into `documentedDeviations`: a
    /// deviation is a decision to differ from the design, this is a decision the
    /// design already made and a later slice carries out. Merging them would
    /// lose which of the two a reader is looking at.
    ///
    /// **One entry, and it is `.inspector` in all four.** §5.1 dissolves the
    /// Inspector into per-persona sections at slice 4. §5.0 is later than §5.1
    /// and keeps it in every persona until then — it anchors the far end of the
    /// canonical order, which is what lets `defaultPane` stay `panes.first` —
    /// so it is *pending*, not *deviant*, everywhere including Publish. What is
    /// particular to Publish is only that it will be the last one slice 4 can
    /// take: `InspectorPublishSection` is the app's sole per-piece publish
    /// config UI. That argument lives at the `.publish` case in `Persona.panes`.
    private static let notYetDelivered: [Persona: Set<DetailSegment>] = [
        .plan: [.inspector],
        .author: [.inspector],
        .review: [.inspector],
        .publish: [.inspector]
    ]

    /// Deviations the registry takes on purpose, each argued at its case in
    /// `Persona.panes`. Listing them here is what makes the matrix test able to
    /// fail on an oversight: anything outside matrix ∪ deviations ∪ pending is
    /// a pane nobody decided to add.
    ///
    /// **Empty as of §5.0, and the mechanism is kept rather than deleted.** Its
    /// one entry was Publish's `.inspector`, which §6.3 marked `—`; §5.0 gives
    /// Inspector to all four personas, so that cell stopped being a departure
    /// from the design and moved to `notYetDelivered` with the other three. An
    /// empty list here is a claim in its own right — every pane this registry
    /// offers is one some design document asks for.
    private static let documentedDeviations: [Persona: Set<DetailSegment>] = [:]

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
