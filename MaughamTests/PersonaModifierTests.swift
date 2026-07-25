import XCTest
import MaughamCore
@testable import Maugham

@MainActor
final class PersonaModifierTests: XCTestCase {
    func test_applyPersonaChange_coercesASegmentTheDestinationLacks() {
        // Sitting on Annotations in Review, then switching to Author, which
        // does not offer it. Landing on a blank pane would read as a bug.
        let result = PersonaModifier.applyPersonaChange(
            to: .author, currentSegment: .annotations,
            currentBinderSegment: .manuscript, projectType: .novel)
        XCTAssertEqual(result.persona, .author)
        XCTAssertEqual(result.segment, Persona.author.defaultPane)
    }

    func test_applyPersonaChange_keepsASegmentTheDestinationOffers() {
        let result = PersonaModifier.applyPersonaChange(
            to: .review, currentSegment: .outline,
            currentBinderSegment: .manuscript, projectType: .novel)
        XCTAssertEqual(result.segment, .outline, "Outline exists in Review; don't disturb it")
    }

    func test_applyPersonaChange_toTheSamePersona_isIdentity() {
        let result = PersonaModifier.applyPersonaChange(
            to: .author, currentSegment: .tasks,
            currentBinderSegment: .manuscript, projectType: .novel)
        XCTAssertEqual(result.persona, .author)
        XCTAssertEqual(result.segment, .tasks)
    }

    func test_applyPersonaChange_movesBinderHomeWhenTheSegmentIsUnavailable() {
        let result = PersonaModifier.applyPersonaChange(
            to: .plan, currentSegment: .inspector,
            currentBinderSegment: .manuscript, projectType: .novel)
        XCTAssertEqual(result.binderSegment, .research)
    }

    func test_applyPersonaChange_preservesAnActiveFind() {
        let result = PersonaModifier.applyPersonaChange(
            to: .plan, currentSegment: .inspector,
            currentBinderSegment: .find, projectType: .novel)
        XCTAssertEqual(result.binderSegment, .find, "switching persona must not cancel a search")
    }

    func test_applyPersonaChange_keepsABinderSegmentTheDestinationOffers() {
        let result = PersonaModifier.applyPersonaChange(
            to: .plan, currentSegment: .inspector,
            currentBinderSegment: .palette, projectType: .novel)
        XCTAssertEqual(result.binderSegment, .palette, "Plan offers Palette; don't disturb it")
    }

    func test_applyPersonaChange_neverLandsAScreenplayOnManuscript() {
        // A screenplay binder has no Manuscript segment (2026-07-02 smoke).
        for persona in Persona.allCases {
            let result = PersonaModifier.applyPersonaChange(
                to: persona, currentSegment: .inspector,
                currentBinderSegment: .palette, projectType: .screenplay)
            XCTAssertNotEqual(result.binderSegment, .manuscript, "\(persona)")
        }
    }

    func test_personaFromPayload_parsesAValidRawValue() {
        XCTAssertEqual(PersonaModifier.persona(fromPayload: "review"), .review)
    }

    func test_personaFromPayload_rejectsGarbage() {
        XCTAssertNil(PersonaModifier.persona(fromPayload: "nonsense"))
        XCTAssertNil(PersonaModifier.persona(fromPayload: nil))
    }
}
