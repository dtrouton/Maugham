import XCTest
import MaughamCore
@testable import Maugham

/// `PersonaMemory` is the pure core of defect B's fix (2026-07-25 smoke): a
/// persona switch is a workspace switch, so each persona keeps its own two
/// column selections. The wiring lives in `PersonaModifier` and is pinned by
/// `PersonaModifierTests`; everything reachable without SwiftUI is pinned here.
final class PersonaMemoryTests: XCTestCase {

    // MARK: - Defaults

    func test_empty_fallsBackToEachPersonasOwnHome() {
        for type in ProjectType.allCases {
            for persona in Persona.allCases {
                XCTAssertEqual(
                    PersonaMemory.empty.restoredBinderSegment(for: persona, projectType: type),
                    persona.binderHome(for: type), "\(persona) on \(type)")
                XCTAssertEqual(
                    PersonaMemory.empty.restoredDetailSegment(for: persona),
                    persona.defaultPane, "\(persona)")
            }
        }
    }

    // MARK: - Recording and restoring

    // **THE BINDER HALF OF THESE TESTS IS DRIVEN THROUGH PLAN, and it has to
    // be.** `restoredBinderSegment` filters a remembered value against the
    // persona's own registry and falls back to its home, so a fixture the
    // persona does not offer makes the test assert THE FALLBACK while reading
    // like a round trip — green whatever `record` does.
    //
    // They used `.research` on Author until task 6 of the persona shell's
    // slice 2 (§6.1), then `.palette` on Author until task 6b took that too.
    // Author now offers exactly `[home]`, and so do Review and Publish, so
    // **Plan is the only persona left with a non-home binder segment to test
    // with at all** (§6.2 records that shape and leaves it deliberately
    // unresolved until after slice 7). Each fixture below states its premise
    // rather than trusting the registry to still hold it.
    //
    // The DETAIL half stays on both personas: `panes` has a two-entry floor
    // (`PersonaPaneRegistryTests.test_everyPersona_offersAtLeastTwoPanes`), so
    // every persona still has a non-default pane to distinguish with.

    /// Premise the binder fixtures share: the value must be one Plan offers and
    /// must differ from what a dropped entry would produce.
    private func assertPlanDistinguishes(_ segment: BinderSegment,
                                         file: StaticString = #filePath,
                                         line: UInt = #line) {
        XCTAssertTrue(Persona.plan.binderSegments(for: .novel).contains(segment),
                      "premise: Plan must offer \(segment), or restore filters it",
                      file: file, line: line)
        XCTAssertNotEqual(Persona.plan.binderHome(for: .novel), segment,
                          "premise: \(segment) must differ from the fallback, or "
                          + "the assertion cannot see the difference",
                          file: file, line: line)
    }

    func test_record_thenRestore_returnsTheSameSegments() {
        assertPlanDistinguishes(.palette)
        var memory = PersonaMemory.empty
        memory.record(persona: .plan, binderSegment: .palette, detailSegment: .inbox)
        XCTAssertEqual(memory.restoredBinderSegment(for: .plan, projectType: .novel), .palette)
        XCTAssertEqual(memory.restoredDetailSegment(for: .plan), .inbox)
    }

    func test_record_isPerPersona() {
        assertPlanDistinguishes(.palette)
        var memory = PersonaMemory.empty
        memory.record(persona: .plan, binderSegment: .palette, detailSegment: .inbox)
        memory.record(persona: .author, binderSegment: .manuscript, detailSegment: .tasks)
        // Plan's entry surviving a later write to Author's key is the binder
        // axis's whole distinguishing power now — a single shared slot would
        // have overwritten it. Author's own binder entry cannot say anything
        // here, because its only offered segment IS its fallback.
        XCTAssertEqual(memory.restoredBinderSegment(for: .plan, projectType: .novel), .palette)
        XCTAssertEqual(memory.restoredDetailSegment(for: .author), .tasks)
        XCTAssertEqual(memory.restoredDetailSegment(for: .plan), .inbox)
    }

    func test_record_overwritesThePreviousValueForThatPersona() {
        // BOTH values are non-home, so a `record` that no-opped entirely would
        // restore `.canvas` and fail, and one that refused to overwrite would
        // restore `.research` and fail. A home-valued second write could not
        // tell either of those from success.
        assertPlanDistinguishes(.research)
        assertPlanDistinguishes(.palette)
        var memory = PersonaMemory.empty
        memory.record(persona: .plan, binderSegment: .research, detailSegment: .inbox)
        memory.record(persona: .plan, binderSegment: .palette, detailSegment: .inspector)
        XCTAssertEqual(memory.restoredBinderSegment(for: .plan, projectType: .novel), .palette)
        XCTAssertEqual(memory.restoredDetailSegment(for: .plan), .inspector)
    }

    // MARK: - Transient segments are never remembered

    func test_record_ignoresTransientBinderSegments() {
        assertPlanDistinguishes(.palette)
        for transient in [BinderSegment.find, .trash] {
            var memory = PersonaMemory.empty
            memory.record(persona: .plan, binderSegment: .palette, detailSegment: .inbox)
            memory.record(persona: .plan, binderSegment: transient, detailSegment: .inspector)
            XCTAssertEqual(
                memory.restoredBinderSegment(for: .plan, projectType: .novel), .palette,
                "\(transient) is a state passed through, not a surface to return to")
            XCTAssertEqual(memory.restoredDetailSegment(for: .plan), .inspector,
                           "the right pane is still recorded — nothing transient there")
        }
    }

    /// Record-then-restore, for every segment there is: the recorded value
    /// comes back exactly when the persona offers it and it is not transient;
    /// otherwise the persona's home does. The transient set is read off
    /// `BinderSegment.isTransient` rather than re-declared here, so a future
    /// runtime-gated segment cannot be remembered by accident.
    func test_recordThenRestore_honoursOfferedAndTransientForEverySegment() {
        let all = BinderSegment.allCases
        for type in ProjectType.allCases {
            for persona in Persona.allCases {
                let offered = persona.binderSegments(for: type)
                for segment in all {
                    var memory = PersonaMemory.empty
                    memory.record(persona: persona,
                                  binderSegment: segment,
                                  detailSegment: .inspector)
                    let expected = (!segment.isTransient && offered.contains(segment))
                        ? segment
                        : persona.binderHome(for: type)
                    XCTAssertEqual(
                        memory.restoredBinderSegment(for: persona, projectType: type),
                        expected, "\(persona)/\(type) recorded \(segment)")
                }
            }
        }
    }

    // MARK: - Validity filtering on restore

    func test_restore_dropsASegmentThePersonaDoesNotOffer() {
        // Plan never offers the manuscript segment.
        let memory = PersonaMemory(binder: ["plan": .manuscript])
        XCTAssertEqual(memory.restoredBinderSegment(for: .plan, projectType: .novel),
                       Persona.plan.binderHome(for: .novel))
    }

    func test_restore_dropsARememberedManuscriptOnAScreenplay() {
        // The project type changed under the memory (or the value came from a
        // different project shape). A screenplay has no Manuscript segment.
        let memory = PersonaMemory(binder: ["author": .manuscript])
        XCTAssertEqual(memory.restoredBinderSegment(for: .author, projectType: .screenplay),
                       .scenes)
    }

    func test_restore_neverResurrectsATransientSegment() {
        for transient in [BinderSegment.find, .trash] {
            let memory = PersonaMemory(binder: ["author": transient])
            for type in ProjectType.allCases {
                XCTAssertNotEqual(
                    memory.restoredBinderSegment(for: .author, projectType: type), transient,
                    "a stale \(transient) must not come back out of the memory")
            }
        }
    }

    func test_restore_dropsAPaneThePersonaDoesNotOffer() {
        // Author does not offer Annotations — adjudicating durable notes is a
        // review activity (`PersonaPaneRegistryTests.test_authorPersona_excludesAnnotations`).
        // This case used History, which Author gained in the persona shell's
        // slice 1; the pane that shipped as summonable-but-forgotten is now one
        // the memory keeps.
        let memory = PersonaMemory(detail: ["author": .annotations])
        XCTAssertEqual(memory.restoredDetailSegment(for: .author), Persona.author.defaultPane)
    }

    /// Exhaustive: whatever is in the memory, a restore always yields
    /// something the persona actually offers. Personas are lenses, not gates —
    /// but the LANDING segment must always be renderable.
    func test_restore_alwaysYieldsAnOfferedSegment() {
        let allBinder = BinderSegment.allCases
        for type in ProjectType.allCases {
            for persona in Persona.allCases {
                for candidate in allBinder {
                    let memory = PersonaMemory(binder: [persona.rawValue: candidate])
                    let restored = memory.restoredBinderSegment(for: persona, projectType: type)
                    XCTAssertTrue(persona.binderSegments(for: type).contains(restored),
                                  "\(persona)/\(type) restored \(restored) from \(candidate)")
                }
                for candidate in DetailSegment.allCases {
                    let memory = PersonaMemory(detail: [persona.rawValue: candidate])
                    XCTAssertTrue(
                        persona.panes.contains(memory.restoredDetailSegment(for: persona)),
                        "\(persona) restored an unoffered pane from \(candidate)")
                }
            }
        }
    }

    // MARK: - Codable

    func test_codable_roundTrip() throws {
        var memory = PersonaMemory.empty
        memory.record(persona: .review, binderSegment: .research, detailSegment: .history)
        let data = try JSONEncoder().encode(memory)
        XCTAssertEqual(try JSONDecoder().decode(PersonaMemory.self, from: data), memory)
    }

    func test_encodedShape_isHumanReadable() throws {
        // `ui-state.json` is a file a writer may open. Keyed by persona raw
        // value, values are segment raw values — not the alternating-array
        // form an enum-keyed dictionary would produce.
        var memory = PersonaMemory.empty
        memory.record(persona: .plan, binderSegment: .palette, detailSegment: .outline)
        let json = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(memory)) as? [String: Any]
        XCTAssertEqual(json?["binder"] as? [String: String], ["plan": "palette"])
        XCTAssertEqual(json?["detail"] as? [String: String], ["plan": "outline"])
    }

    func test_decode_dropsUnknownSegmentValuesWithoutLosingTheRest() throws {
        // A newer build's segment name must cost only its own entry.
        //
        // **The two personas have swapped roles twice, for the same reason both
        // times.** The surviving binder entry must be one its persona OFFERS and
        // that differs from its home, or a filtered restore is indistinguishable
        // from a dropped decode. It was `author: "research"` until slice 2's
        // task 6, then `author: "palette"` until task 6b — which left Author
        // offering only its home, so it is now `plan: "palette"` and Author
        // carries the unknown value instead. The premise below is asserted
        // rather than trusted, and it is the OFFERED half that was missing when
        // task 6b arrived: the old premise checked only that the value differed
        // from the home, which stayed true while the value stopped being offered.
        XCTAssertTrue(Persona.plan.binderSegments(for: .novel).contains(.palette),
                      "premise: the surviving value must be one Plan offers")
        XCTAssertNotEqual(Persona.plan.binderHome(for: .novel), .palette,
                          "premise: and must differ from the fallback, or the "
                          + "assertion below cannot see the difference")
        let json = Data("""
        {"binder":{"author":"moodboard","plan":"palette"},
         "detail":{"author":"telemetry","review":"history"}}
        """.utf8)
        let memory = try JSONDecoder().decode(PersonaMemory.self, from: json)
        XCTAssertEqual(memory.restoredBinderSegment(for: .plan, projectType: .novel), .palette)
        XCTAssertEqual(memory.restoredBinderSegment(for: .author, projectType: .novel),
                       Persona.author.binderHome(for: .novel))
        XCTAssertEqual(memory.restoredDetailSegment(for: .review), .history)
        XCTAssertEqual(memory.restoredDetailSegment(for: .author), Persona.author.defaultPane)
    }

    func test_decode_ofAMalformedMap_isEmptyNotAThrow() throws {
        let json = Data(#"{"binder":"nonsense","detail":42}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(PersonaMemory.self, from: json), .empty)
    }
}
