import XCTest
@testable import Maugham

@MainActor
final class PersonaModifierTests: XCTestCase {
    func test_applyPersonaChange_coercesASegmentTheDestinationLacks() {
        // Sitting on Annotations in Review, then switching to Author, which
        // does not offer it. Landing on a blank pane would read as a bug.
        let result = PersonaModifier.applyPersonaChange(to: .author, currentSegment: .annotations)
        XCTAssertEqual(result.persona, .author)
        XCTAssertEqual(result.segment, Persona.author.defaultPane)
    }

    func test_applyPersonaChange_keepsASegmentTheDestinationOffers() {
        let result = PersonaModifier.applyPersonaChange(to: .review, currentSegment: .outline)
        XCTAssertEqual(result.segment, .outline, "Outline exists in Review; don't disturb it")
    }

    func test_applyPersonaChange_toTheSamePersona_isIdentity() {
        let result = PersonaModifier.applyPersonaChange(to: .author, currentSegment: .tasks)
        XCTAssertEqual(result.persona, .author)
        XCTAssertEqual(result.segment, .tasks)
    }

    func test_personaFromPayload_parsesAValidRawValue() {
        XCTAssertEqual(PersonaModifier.persona(fromPayload: "review"), .review)
    }

    func test_personaFromPayload_rejectsGarbage() {
        XCTAssertNil(PersonaModifier.persona(fromPayload: "nonsense"))
        XCTAssertNil(PersonaModifier.persona(fromPayload: nil))
    }
}
