import XCTest
import MaughamCore
@testable import Maugham

/// `PersonaMemory` is the pure core of defect B's fix (2026-07-25 smoke): a
/// persona switch is a workspace switch, so each persona keeps its own pane
/// selection. The wiring lives in `PersonaModifier` and is pinned by
/// `PersonaModifierTests`; everything reachable without SwiftUI is pinned here.
///
/// **One column since shell-finish stage 2b Task 7.** The binder half of this
/// suite went with `BinderSegment` — the offered-set filtering, the transient
/// exception, the per-project-type fallbacks and the exhaustive
/// record-then-restore over every segment. Every persona's left column is the
/// project's own tree now: there is no position to remember, so there is no
/// round trip for one to be lossy across. The detail half is unchanged and is
/// what these tests are about.
final class PersonaMemoryTests: XCTestCase {

    // MARK: - Defaults

    func test_empty_fallsBackToEachPersonasOwnDefaultPane() {
        for persona in Persona.allCases {
            XCTAssertEqual(
                PersonaMemory.empty.restoredDetailSegment(for: persona),
                persona.defaultPane, "\(persona)")
        }
    }

    // MARK: - Recording and restoring

    // **Every fixture below states its premise rather than trusting the
    // registry to still hold it**, which is the lesson the deleted binder half
    // taught twice: `restoredDetailSegment` filters a remembered value against
    // the persona's own registry and falls back to its default, so a fixture the
    // persona does not offer makes the test assert THE FALLBACK while reading
    // like a round trip — green whatever `record` does.
    //
    // `panes` has a two-entry floor
    // (`PersonaPaneRegistryTests.test_everyPersona_offersAtLeastTwoPanes`), so
    // every persona still has a non-default pane to distinguish with.

    /// The premise the fixtures share: the value must be one the persona offers
    /// and must differ from what a dropped entry would produce.
    private func assertDistinguishes(_ pane: DetailSegment, for persona: Persona,
                                     file: StaticString = #filePath,
                                     line: UInt = #line) {
        XCTAssertTrue(persona.panes.contains(pane),
                      "premise: \(persona) must offer \(pane), or restore filters it",
                      file: file, line: line)
        XCTAssertNotEqual(persona.defaultPane, pane,
                          "premise: \(pane) must differ from the fallback, or "
                          + "the assertion cannot see the difference",
                          file: file, line: line)
    }

    func test_record_thenRestore_returnsTheSamePane() {
        assertDistinguishes(.tasks, for: .plan)
        var memory = PersonaMemory.empty
        memory.record(persona: .plan, detailSegment: .tasks)
        XCTAssertEqual(memory.restoredDetailSegment(for: .plan), .tasks)
    }

    func test_record_isPerPersona() {
        assertDistinguishes(.history, for: .plan)
        assertDistinguishes(.tasks, for: .author)
        var memory = PersonaMemory.empty
        memory.record(persona: .plan, detailSegment: .history)
        memory.record(persona: .author, detailSegment: .tasks)
        // Plan's entry surviving a later write to Author's key is the whole
        // distinguishing power here — a single shared slot would have
        // overwritten it.
        XCTAssertEqual(memory.restoredDetailSegment(for: .author), .tasks)
        XCTAssertEqual(memory.restoredDetailSegment(for: .plan), .history)
    }

    func test_record_overwritesThePreviousValueForThatPersona() {
        // BOTH values are non-default, so a `record` that no-opped entirely
        // would restore the default and fail, and one that refused to overwrite
        // would restore the first value and fail. A default-valued second write
        // could not tell either of those from success.
        assertDistinguishes(.history, for: .plan)
        assertDistinguishes(.inspector, for: .plan)
        var memory = PersonaMemory.empty
        memory.record(persona: .plan, detailSegment: .history)
        memory.record(persona: .plan, detailSegment: .inspector)
        XCTAssertEqual(memory.restoredDetailSegment(for: .plan), .inspector)
    }

    // MARK: - Validity filtering on restore

    func test_restore_dropsAPaneThePersonaDoesNotOffer() {
        // Author does not offer Annotations — adjudicating durable notes is a
        // review activity (`PersonaPaneRegistryTests.test_authorPersona_excludesAnnotations`).
        // This case used History, which Author gained in the persona shell's
        // slice 1; the pane that shipped as summonable-but-forgotten is now one
        // the memory keeps.
        let memory = PersonaMemory(detail: ["author": .annotations])
        XCTAssertEqual(memory.restoredDetailSegment(for: .author), Persona.author.defaultPane)
    }

    /// Exhaustive: whatever is in the memory, a restore always yields something
    /// the persona actually offers. Personas are lenses, not gates — but the
    /// LANDING pane must always be renderable.
    func test_restore_alwaysYieldsAnOfferedPane() {
        for persona in Persona.allCases {
            for candidate in DetailSegment.allCases {
                let memory = PersonaMemory(detail: [persona.rawValue: candidate])
                XCTAssertTrue(
                    persona.panes.contains(memory.restoredDetailSegment(for: persona)),
                    "\(persona) restored an unoffered pane from \(candidate)")
            }
        }
    }

    // MARK: - Codable

    func test_codable_roundTrip() throws {
        var memory = PersonaMemory.empty
        memory.record(persona: .review, detailSegment: .history)
        let data = try JSONEncoder().encode(memory)
        XCTAssertEqual(try JSONDecoder().decode(PersonaMemory.self, from: data), memory)
    }

    func test_encodedShape_isHumanReadable() throws {
        // `ui-state.json` is a file a writer may open. Keyed by persona raw
        // value, values are pane raw values — not the alternating-array form an
        // enum-keyed dictionary would produce.
        var memory = PersonaMemory.empty
        memory.record(persona: .plan, detailSegment: .tasks)
        let json = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(memory)) as? [String: Any]
        XCTAssertEqual(json?["detail"] as? [String: String], ["plan": "tasks"])
    }

    func test_decode_dropsUnknownPaneValuesWithoutLosingTheRest() throws {
        // A newer build's pane name must cost only its own entry.
        //
        // The premise is asserted rather than trusted, and the OFFERED half is
        // the one that was missing when slice 2's task 6b arrived on the binder
        // twin of this test: the old premise checked only that the value
        // differed from the fallback, which stayed true while the value stopped
        // being offered.
        assertDistinguishes(.history, for: .review)
        let json = Data("""
        {"detail":{"author":"telemetry","review":"history"}}
        """.utf8)
        let memory = try JSONDecoder().decode(PersonaMemory.self, from: json)
        XCTAssertEqual(memory.restoredDetailSegment(for: .review), .history)
        XCTAssertEqual(memory.restoredDetailSegment(for: .author), Persona.author.defaultPane)
    }

    /// **A `ui-state.json` written before Task 7 still carries a `binder` map,
    /// and it costs nothing** (tripwire 11 — no migration). The keyed container
    /// never asks for the key, so the value decodes away; the `detail` map
    /// beside it comes through untouched, which is the half that would have been
    /// lost by a decoder that threw on the shape it did not recognise.
    func test_decode_ignoresALegacyBinderMapAndKeepsTheDetailBeside() throws {
        let json = Data("""
        {"binder":{"plan":"palette","author":"manuscript"},
         "detail":{"review":"history"}}
        """.utf8)
        let memory = try JSONDecoder().decode(PersonaMemory.self, from: json)
        XCTAssertEqual(memory.restoredDetailSegment(for: .review), .history,
                       "the right column's memory survives a file written by a "
                       + "build that still had a left one")
        XCTAssertEqual(memory, PersonaMemory(detail: ["review": .history]),
                       "and nothing of the legacy map is retained")
    }

    func test_decode_ofAMalformedMap_isEmptyNotAThrow() throws {
        let json = Data(#"{"binder":"nonsense","detail":42}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(PersonaMemory.self, from: json), .empty)
    }

    // MARK: - The three retired segments (stage 3a Task 6, tripwire 11)

    /// **No migration — a stored `.outline`/`.research`/`.palette` entry is
    /// absorbed by the same tolerant decode that already drops any unknown
    /// pane name.** The three raw values are written directly as JSON text,
    /// never through the Swift enum — `DetailSegment.outline` etc. no longer
    /// exist to construct. `compactMapValues(DetailSegment.init(rawValue:))`
    /// drops each one on its own, and `restoredDetailSegment` falls back to
    /// the persona's default exactly as it does for any other unrecognised
    /// name.
    func test_decode_retiredSegmentsFallBackToTheirPersonasDefault() throws {
        for (persona, retired) in [
            (Persona.plan, "outline"), (Persona.author, "research"), (Persona.author, "palette"),
        ] {
            let json = Data(
                "{\"detail\":{\"\(persona.rawValue)\":\"\(retired)\"}}".utf8)
            let memory = try JSONDecoder().decode(PersonaMemory.self, from: json)
            XCTAssertEqual(memory.restoredDetailSegment(for: persona), persona.defaultPane,
                           "\(persona) restored from a stored \"\(retired)\" instead of "
                           + "falling back to its default")
        }
    }
}
