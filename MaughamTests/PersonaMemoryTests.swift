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

    func test_record_thenRestore_returnsTheSameSegments() {
        var memory = PersonaMemory.empty
        memory.record(persona: .author, binderSegment: .research, detailSegment: .tasks)
        XCTAssertEqual(memory.restoredBinderSegment(for: .author, projectType: .novel), .research)
        XCTAssertEqual(memory.restoredDetailSegment(for: .author), .tasks)
    }

    func test_record_isPerPersona() {
        var memory = PersonaMemory.empty
        memory.record(persona: .author, binderSegment: .research, detailSegment: .tasks)
        memory.record(persona: .plan, binderSegment: .palette, detailSegment: .outline)
        XCTAssertEqual(memory.restoredBinderSegment(for: .author, projectType: .novel), .research)
        XCTAssertEqual(memory.restoredBinderSegment(for: .plan, projectType: .novel), .palette)
        XCTAssertEqual(memory.restoredDetailSegment(for: .author), .tasks)
        XCTAssertEqual(memory.restoredDetailSegment(for: .plan), .outline)
    }

    func test_record_overwritesThePreviousValueForThatPersona() {
        var memory = PersonaMemory.empty
        memory.record(persona: .author, binderSegment: .research, detailSegment: .tasks)
        memory.record(persona: .author, binderSegment: .manuscript, detailSegment: .inspector)
        XCTAssertEqual(memory.restoredBinderSegment(for: .author, projectType: .novel), .manuscript)
        XCTAssertEqual(memory.restoredDetailSegment(for: .author), .inspector)
    }

    // MARK: - Transient segments are never remembered

    func test_record_ignoresTransientBinderSegments() {
        for transient in [BinderSegment.find, .trash] {
            var memory = PersonaMemory.empty
            memory.record(persona: .author, binderSegment: .research, detailSegment: .tasks)
            memory.record(persona: .author, binderSegment: transient, detailSegment: .inspector)
            XCTAssertEqual(
                memory.restoredBinderSegment(for: .author, projectType: .novel), .research,
                "\(transient) is a state passed through, not a surface to return to")
            XCTAssertEqual(memory.restoredDetailSegment(for: .author), .inspector,
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
        // Author does not offer History.
        let memory = PersonaMemory(detail: ["author": .history])
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
        let json = Data("""
        {"binder":{"plan":"moodboard","author":"research"},
         "detail":{"author":"telemetry","review":"history"}}
        """.utf8)
        let memory = try JSONDecoder().decode(PersonaMemory.self, from: json)
        XCTAssertEqual(memory.restoredBinderSegment(for: .author, projectType: .novel), .research)
        XCTAssertEqual(memory.restoredBinderSegment(for: .plan, projectType: .novel),
                       Persona.plan.binderHome(for: .novel))
        XCTAssertEqual(memory.restoredDetailSegment(for: .review), .history)
        XCTAssertEqual(memory.restoredDetailSegment(for: .author), Persona.author.defaultPane)
    }

    func test_decode_ofAMalformedMap_isEmptyNotAThrow() throws {
        let json = Data(#"{"binder":"nonsense","detail":42}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(PersonaMemory.self, from: json), .empty)
    }
}
